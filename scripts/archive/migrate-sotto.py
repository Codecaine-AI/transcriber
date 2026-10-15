#!/usr/bin/env python3
"""One-off move of the transcript archive from the `sotto` source id to `transcriber`.

Subcommands: plan (read-only), backup, migrate, verify, rollback. Run them in that order with the
archive and server services stopped (see migrate-sotto-launchd.sh). Every step refuses to continue
on anything it does not expect. Source versions, transcripts and audio are never rewritten; only
three fields of each metadata.json change (source, selected_source, source_versions[].role).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import difflib
import json
import os
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from archive import atomic, digest, encode  # noqa: E402  (same bytes and fsync as the worker)

OLD, NEW = 'sotto', 'transcriber'
OLD_ROLE, NEW_ROLE = OLD + '-metadata', NEW + '-metadata'
LABELS = ('server', 'archive', 'app')
LOCAL_PLISTS = ('archive', 'server')
LAUNCHERS = ('Start Transcriber.command', 'Start Sotto.command')
PORTS = (8391, 8392)
STEPS = ('move', 'metadata', 'index', 'manifests', 'state', 'config')
ROLE_PATH = re.compile(r'^\.source_versions\[\d+\]\.role$')
ALLOWED_DIFFS = {'.source', '.selected_source'}
UUID_DIR = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
WORKERS = 8


class Surprise(Exception):
    pass


def now():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def say(tag, text):
    print(f'[{tag}] {text}', flush=True)


def main_repo():
    out = subprocess.run(['git', '-C', str(HERE), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                         capture_output=True, text=True, check=True).stdout.strip()
    return Path(out).parent


# ---------------------------------------------------------------- context

class Ctx:
    def __init__(self, args):
        self.transcripts = Path(args.transcripts).expanduser().resolve()
        self.repo = Path(args.repo).expanduser().resolve()
        self.cache = Path(args.cache).expanduser().resolve() if args.cache else self.repo / '.local' / 'archive-cache'
        self.agents = Path(args.launch_agents).expanduser().resolve()
        self.local = self.repo / '.local'
        self.config = self.local / 'archive-config.json'
        self.records = self.transcripts / 'records'
        self.old_dir = self.records / OLD
        self.new_dir = self.records / NEW
        self.wispr_dir = self.records / 'wispr-flow'
        self.index = self.cache / 'index.sqlite'
        self.old_state = self.cache / f'{OLD}-state.json'
        self.new_state = self.cache / f'{NEW}-state.json'
        self.state_prefix = str(self.repo / '.local' / 'server' / 'generations') + '/'
        self.skip_services = getattr(args, 'unsafe_skip_service_check', False)
        real = main_repo()
        self.is_real = (self.transcripts == (Path.home() / 'Transcripts').resolve() or self.repo == real
                        or self.cache.is_relative_to(real))
        if self.skip_services and self.is_real:
            raise SystemExit('--unsafe-skip-service-check is refused for the real archive, repo or cache.')

    def plist(self, label, base=None):
        return (base or self.agents) / f'ai.codecaine.{OLD}.{label}.plist'


# ---------------------------------------------------------------- helpers

def walk(base):
    """Relative posix paths of every regular file under base; .DS_Store is listed separately."""
    files, junk = [], []
    for root, dirs, names in os.walk(base):
        dirs.sort()
        for name in sorted(names):
            p = Path(root) / name
            rel = p.relative_to(base).as_posix()
            if p.is_symlink() or not p.is_file():
                raise Surprise(f'Not a regular file: {p}')
            (junk if name == '.DS_Store' else files).append(rel)
    return files, junk


def hash_many(base, rels, label):
    started = time.monotonic()
    total = sum((base / r).stat().st_size for r in rels)
    done = [0, 0]
    step = max(1, len(rels) // 10)

    def one(rel):
        return rel, digest(base / rel)

    out = {}
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        for rel, sha in pool.map(one, rels):
            out[rel] = sha
            done[0] += 1
            if done[0] % step == 0:
                print(f'    {label}: {done[0]}/{len(rels)} files', file=sys.stderr, flush=True)
    seconds = time.monotonic() - started
    say('time', f'{label}: hashed {len(rels)} files, {total / 1e9:.2f} GB in {seconds:.1f}s'
                f' ({total / 1e6 / max(seconds, 1e-6):.0f} MB/s)')
    return out, total, seconds


def is_meta(rel):
    return rel.count('/') == 1 and rel.endswith('/metadata.json')


def transform(m, frm, to):
    """Return a copy of metadata with exactly the three source fields renamed; refuse anything else."""
    roles = [v.get('role') for v in m.get('source_versions', [])]
    if m.get('source') != frm or m.get('selected_source') != frm or any(r != frm + '-metadata' for r in roles):
        raise Surprise(f'{m.get("id")}: expected source/selected_source {frm!r} and roles {frm}-metadata, '
                       f'found {m.get("source")!r}/{m.get("selected_source")!r}/{sorted(set(roles))}')
    n = json.loads(json.dumps(m))
    n['source'] = n['selected_source'] = to
    for v in n['source_versions']:
        v['role'] = to + '-metadata'
    return n


def diff_paths(a, b, p=''):
    if type(a) is not type(b):
        yield p
    elif isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                yield f'{p}.{k}'
            else:
                yield from diff_paths(a[k], b[k], f'{p}.{k}')
    elif isinstance(a, list):
        if len(a) != len(b):
            yield p
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                yield from diff_paths(x, y, f'{p}[{i}]')
    elif a != b:
        yield p


def show_diff(name, before, after):
    lines = list(difflib.unified_diff(before.decode().splitlines(), after.decode().splitlines(),
                                      f'a/{name}', f'b/{name}', lineterm='', n=1))
    for line in lines:
        print('    ' + line)
    return bool(lines)


def ro(path):
    return sqlite3.connect(Path(path).as_uri() + '?mode=ro', uri=True)


def index_counts(db):
    return dict(db.execute('select source, count(*) from records group by source').fetchall())


def services():
    uid = os.getuid()
    loaded = {}
    for prefix in (OLD, NEW):
        for label in LABELS:
            name = f'ai.codecaine.{prefix}.{label}'
            loaded[name] = subprocess.run(['launchctl', 'print', f'gui/{uid}/{name}'],
                                          capture_output=True).returncode == 0
    ports = {}
    for port in PORTS:
        out = subprocess.run(['lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-Fpc'], capture_output=True, text=True).stdout
        ports[port] = ' '.join(x[1:] for x in out.split() if x[:1] in 'pc')
    return loaded, ports


def require_stopped(ctx):
    if ctx.skip_services:
        say('warn', 'service check skipped (scratch rehearsal only)')
        return
    loaded, ports = services()
    busy = [k for k, v in loaded.items() if v] + [f'port {p} ({w})' for p, w in ports.items() if w]
    if busy:
        raise Surprise('Stop the services first (migrate-sotto-launchd.sh down). Still active: ' + ', '.join(busy))
    say('ok', 'services stopped: no sotto/transcriber labels loaded, ports 8391/8392 closed')


def copy_exact(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if digest(src) != digest(dst):
        raise Surprise(f'Copy differs: {src}')


def load_json(path):
    return json.loads(Path(path).read_text())


# ---------------------------------------------------------------- inspection (plan + preconditions)

def inspect(ctx, strict_services=False):
    """Read-only survey. Returns facts; raises nothing, collects surprises."""
    s, f = [], {}

    def surprise(text):
        s.append(text)
        say('SURPRISE', text)

    ds = ctx.transcripts / 'dataset.json'
    if not ds.is_file() or load_json(ds).get('format') != 'codecaine-transcripts':
        surprise(f'{ds} is missing or not a codecaine-transcripts dataset')
        return f, s
    entries = sorted(p.name for p in ctx.records.iterdir())
    if ctx.new_dir.exists():
        surprise(f'{ctx.new_dir} already exists')
    if [e for e in entries if e != '.DS_Store'] != [OLD, 'wispr-flow']:
        surprise(f'records/ holds {entries}; expected exactly sotto and wispr-flow')
    if not ctx.old_dir.is_dir():
        surprise('records/sotto is missing')
        return f, s

    ids, junk = [], []
    for p in sorted(ctx.old_dir.iterdir()):
        if p.name == '.DS_Store':
            junk.append(p.name)
        elif p.is_dir() and UUID_DIR.match(p.name):
            ids.append(p.name)
        else:
            surprise(f'unexpected entry in records/sotto: {p.name}')
    f['ids'] = ids
    f['records'] = n = len(ids)
    say('ok' if n else 'SURPRISE', f'records/sotto: {n} record folders' + (f' (+{len(junk)} .DS_Store)' if junk else ''))

    roles, selected, versions, bad = {}, {}, 0, 0
    for rid in ids:
        p = ctx.old_dir / rid / 'metadata.json'
        try:
            raw = p.read_bytes()
            m = json.loads(raw)
            if m.get('id') != rid:
                raise Surprise(f'{rid}: metadata id {m.get("id")!r} differs from its folder')
            if encode(m) != raw:
                raise Surprise(f'{rid}: metadata.json does not round-trip byte-for-byte through encode()')
            transform(m, OLD, NEW)
            selected[m.get('selected_source')] = selected.get(m.get('selected_source'), 0) + 1
            for v in m['source_versions']:
                roles[v['role']] = roles.get(v['role'], 0) + 1
                versions += 1
        except (Surprise, ValueError, OSError) as e:
            bad += 1
            if bad <= 5:
                surprise(str(e))
    if bad:
        surprise(f'{bad} metadata files cannot be migrated safely')
    else:
        say('change', f'{n} metadata.json files: source sotto->transcriber ({n}), selected_source ({selected}), '
                      f'source_versions role sotto-metadata->transcriber-metadata ({versions} entries {roles})')

    wispr = sum(1 for p in ctx.wispr_dir.iterdir() if p.is_dir())
    f['wispr'] = wispr
    say('ok', f'records/wispr-flow: {wispr} record folders (untouched)')

    # Index
    if not ctx.index.is_file():
        surprise(f'{ctx.index} is missing')
    else:
        db = ro(ctx.index)
        try:
            counts = index_counts(db)
            f['index_counts'] = counts
            bad_rows = db.execute("select count(*) from records where source='sotto' and "
                                  "(substr(key,1,6)!='sotto/' or path!='records/'||key)").fetchone()[0]
            index_ids = sorted(r[0] for r in db.execute("select substr(key,7) from records where source='sotto'"))
        finally:
            db.close()
        if counts.get(OLD) != n or counts.get('wispr-flow') != wispr or set(counts) != {OLD, 'wispr-flow'}:
            surprise(f'index rows by source {counts} do not match folders (sotto {n}, wispr-flow {wispr})')
        elif bad_rows or index_ids != ids:
            surprise(f'index sotto rows disagree with folders ({bad_rows} malformed key/path rows)')
        else:
            say('change', f'index: UPDATE {n} rows key/source/path sotto->transcriber; wispr-flow {wispr} rows unchanged')

    # Worker state
    if ctx.new_state.exists():
        surprise(f'{ctx.new_state} already exists')
    if not ctx.old_state.is_file():
        surprise(f'{ctx.old_state} is missing')
    else:
        state = load_json(ctx.old_state)
        keep = {k: v for k, v in state.items() if k.startswith(ctx.state_prefix)}
        f['state_keep'] = len(keep)
        key_ids = sorted({Path(k).parent.name.lower() for k in keep})
        if len(keep) != n or key_ids != ids:
            surprise(f'state: {len(keep)} keys under {ctx.state_prefix} (expected {n} matching record ids)')
        else:
            say('change', f'state: write {NEW}-state.json with {len(keep)} current-repo keys; drop {len(state) - len(keep)} '
                          f'stale keys from old repo paths; move {OLD}-state.json into the backup')

    # Config
    if not ctx.config.is_file():
        surprise(f'{ctx.config} is missing')
    else:
        cfg = load_json(ctx.config)
        if 'sotto_data' not in cfg or 'transcriber_data' in cfg:
            surprise(f'archive-config.json keys {sorted(cfg)}; expected sotto_data only')
        else:
            say('change', f'archive-config.json: sotto_data={cfg["sotto_data"]!r} -> '
                          f'transcriber_data={str(ctx.repo / ".local/server")!r}')

    # Top-level manifests
    for p in sorted(ctx.transcripts.iterdir()):
        if not p.is_file() or p.name == '.DS_Store':
            continue
        text = p.read_text(errors='replace')
        if 'sotto' not in text.lower():
            continue
        if p.name == 'dataset.json':
            d = json.loads(text)
            if encode(d) != p.read_bytes() or d.get('sources') != ['wispr-flow', OLD]:
                surprise(f'dataset.json sources {d.get("sources")} or bytes are not as expected')
            else:
                after = dict(d, sources=['wispr-flow', NEW])
                say('change', 'dataset.json:')
                show_diff('dataset.json', p.read_bytes(), encode(after))
        elif p.name in ('completeness.json', 'installation.json'):
            hits = sorted(set(re.findall(r'"[^"\n]*sotto[^"\n]*"', text, re.I)))
            say('keep', f'{p.name} mentions sotto only as historical paths/keys, left as is: {hits}')
        else:
            surprise(f'{p.name} mentions sotto; not handled by this tool')

    # launchd, launchers, services
    for label in LABELS:
        p = ctx.plist(label)
        if not p.is_file():
            surprise(f'missing {p}')
    for p in sorted(ctx.agents.glob(f'ai.codecaine.{NEW}.*.plist')):
        surprise(f'{p} already exists')
    for label in LOCAL_PLISTS:
        p = ctx.plist(label, ctx.local)
        say('ok' if p.is_file() else 'warn', f'.local copy {p.name}: {"present" if p.is_file() else "absent"}')
    for name in LAUNCHERS:
        p = ctx.local / name
        if p.is_file():
            say('change', f'launcher {name}: handled by migrate-sotto-launchd.sh up '
                          f'({"rewritten" if "Transcriber" in name else "stale; moved into the backup"})')
    loaded, ports = services()
    f['services'] = (loaded, ports)
    active = [k for k, v in loaded.items() if v]
    say('info', f'launchd loaded: {active or "none"}; listening: '
                f'{ {p: w or "closed" for p, w in ports.items()} }')
    if any(loaded[f'ai.codecaine.{NEW}.{x}'] for x in LABELS):
        surprise('a transcriber label is already loaded')
    if strict_services and (active or any(ports.values())):
        surprise('services must be stopped for this step')

    code = (ctx.repo / 'scripts/archive/archive.py').read_text()
    say('info', 'repo scripts/archive/archive.py is ' +
        ('the NEW transcriber code' if "'--transcriber-data'" in code else
         'still the OLD sotto code: merge the rename before `migrate-sotto-launchd.sh up`'))

    usage = shutil.disk_usage(ctx.transcripts)
    need = 5 * 1024 ** 3 + 2 * sum(p.stat().st_size for p in ctx.cache.glob('index.sqlite*'))
    f['free'] = usage.free
    if usage.free < need:
        surprise(f'free space {usage.free / 1e9:.1f} GB < required {need / 1e9:.1f} GB')
    else:
        say('ok', f'free space {usage.free / 1e9:.0f} GB (clone is copy-on-write; need ~{need / 1e9:.1f} GB)')
    return f, s


def cmd_plan(ctx, args):
    say('info', f'transcripts={ctx.transcripts} cache={ctx.cache} repo={ctx.repo} launch_agents={ctx.agents}')
    f, s = inspect(ctx)
    started = time.monotonic()
    all_files, _ = walk(ctx.transcripts)
    say('info', f'{len(all_files)} files under {ctx.transcripts} (walked in {time.monotonic() - started:.1f}s)')
    if args.measure_mb and f.get('ids'):
        budget, sample = args.measure_mb * 1e6, []
        rels = [r for r in walk(ctx.old_dir)[0] if not is_meta(r)]
        random.Random(7).shuffle(rels)
        for r in rels:
            if budget <= 0:
                break
            sample.append(r)
            budget -= (ctx.old_dir / r).stat().st_size
        _, total, sec = hash_many(ctx.old_dir, sample, 'throughput sample')
        size = sum((ctx.old_dir / r).stat().st_size for r in rels)
        rate = total / max(sec, 1e-6)
        say('estimate', f'records/sotto non-metadata payload {size / 1e9:.1f} GB in {len(rels)} files: '
                        f'~{size / rate:.0f}s per full hash pass at {rate / 1e6:.0f} MB/s (page cache may flatter this)')
    if s:
        say('FAIL', f'{len(s)} surprise(s); fix them before backup/migrate')
        return 1
    say('PASS', 'plan found nothing unexpected')
    return 0


# ---------------------------------------------------------------- backup

def cmd_backup(ctx, args):
    dest = Path(args.dest).expanduser().resolve()
    if dest.exists() and any(dest.iterdir()):
        raise Surprise(f'{dest} exists and is not empty')
    for inside in (ctx.transcripts, ctx.cache):
        if dest == inside or dest.is_relative_to(inside):
            raise Surprise(f'backup must live outside {inside}')
    require_stopped(ctx)
    dest.mkdir(parents=True, exist_ok=True)
    if dest.stat().st_dev != ctx.transcripts.stat().st_dev:
        raise Surprise('backup must be on the same APFS volume as the archive so cp -c can clone')
    f, s = inspect(ctx, strict_services=not ctx.skip_services)
    if s:
        raise Surprise(f'{len(s)} precondition(s) failed; run plan')

    started = time.monotonic()
    clone = dest / 'Transcripts'
    subprocess.run(['cp', '-c', '-p', '-R', str(ctx.transcripts), str(clone)], check=True)
    say('time', f'APFS clone of {ctx.transcripts} in {time.monotonic() - started:.1f}s')

    db_copy = dest / 'cache' / 'index.sqlite'
    db_copy.parent.mkdir(parents=True)
    src, dst = ro(ctx.index), sqlite3.connect(db_copy)
    try:
        src.backup(dst)
        if index_counts(dst) != index_counts(src):
            raise Surprise('index backup row counts differ')
    finally:
        src.close()
        dst.close()
    copy_exact(ctx.old_state, dest / 'cache' / ctx.old_state.name)
    copy_exact(ctx.config, dest / 'repo-local' / ctx.config.name)
    for label in LOCAL_PLISTS:
        if ctx.plist(label, ctx.local).is_file():
            copy_exact(ctx.plist(label, ctx.local), dest / 'repo-local' / ctx.plist(label).name)
    for name in LAUNCHERS:
        if (ctx.local / name).is_file():
            copy_exact(ctx.local / name, dest / 'repo-local' / name)
    for label in LABELS:
        copy_exact(ctx.plist(label), dest / 'launchd' / 'LaunchAgents' / ctx.plist(label).name)
    say('ok', 'copied index (sqlite backup API), state, config, .local plists, launchers, LaunchAgents plists')

    rels, junk = walk(ctx.old_dir)
    payload = [r for r in rels if not is_meta(r)]
    metas = [r for r in rels if is_meta(r)]
    if len(metas) != f['records']:
        raise Surprise('metadata count changed during backup')
    hashes, total, sec = hash_many(ctx.old_dir, rels, 'records/sotto (all files)')
    manifest = {'files': {r: [(ctx.old_dir / r).stat().st_size, hashes[r]] for r in payload},
                'metadata': {r: hashes[r] for r in metas}, 'ignored': junk}
    atomic(dest / 'hashes.json', encode(manifest))

    live_all, _ = walk(ctx.transcripts)
    clone_all, _ = walk(clone)
    if live_all != clone_all:
        raise Surprise(f'clone file set differs: live {len(live_all)} vs clone {len(clone_all)}')
    sample = random.Random(11).sample(payload, min(200, len(payload)))
    check = {r: digest(clone / 'records' / OLD / r) for r in sample + metas}
    wrong = [r for r in sample if check[r] != manifest['files'][r][1]] + \
            [r for r in metas if check[r] != manifest['metadata'][r]]
    if wrong:
        raise Surprise(f'clone hashes differ for {wrong[:5]}')
    say('ok', f'clone verified: {len(clone_all)} files (same set as live), all {len(metas)} metadata + '
              f'{len(sample)} sampled payload hashes match')

    info = {'status': 'complete', 'created_at': now(), 'transcripts': str(ctx.transcripts), 'cache': str(ctx.cache),
            'repo': str(ctx.repo), 'launch_agents': str(ctx.agents), 'records': f['records'], 'wispr': f['wispr'],
            'index_counts': f['index_counts'], 'state_keep': f['state_keep'], 'payload_files': len(payload),
            'payload_bytes': sum(v[0] for v in manifest['files'].values()), 'hash_seconds': round(sec, 1),
            'clone_files': len(clone_all)}
    atomic(dest / 'backup.json', encode(info))
    say('PASS', f'backup complete in {time.monotonic() - started:.0f}s: {dest}')
    return 0


def load_backup(ctx, path):
    dest = Path(path).expanduser().resolve()
    info = load_json(dest / 'backup.json')
    if info.get('status') != 'complete':
        raise Surprise('backup is incomplete')
    for key, value in (('transcripts', ctx.transcripts), ('cache', ctx.cache), ('repo', ctx.repo)):
        if info[key] != str(value):
            raise Surprise(f'backup was taken for {key}={info[key]}, not {value}')
    manifest = load_json(dest / 'hashes.json')
    if len(manifest['metadata']) != info['records']:
        raise Surprise('backup manifest is inconsistent')
    return dest, info, manifest


# ---------------------------------------------------------------- migrate

def cmd_migrate(ctx, args):
    dest, info, manifest = load_backup(ctx, args.backup)
    journal_path = dest / 'journal.json'
    journal = load_json(journal_path) if journal_path.exists() else {'status': 'new', 'steps': {}}
    if journal['status'] in ('complete', 'rolled-back'):
        raise Surprise(f'migration already {journal["status"]} for this backup; refusing to run twice')
    require_stopped(ctx)
    if journal['status'] == 'running':
        say('info', f'resuming; finished steps: {[k for k, v in journal["steps"].items() if "finished_at" in v]}')
    else:
        _, s = inspect(ctx, strict_services=not ctx.skip_services)
        if s:
            raise Surprise(f'{len(s)} precondition(s) failed; run plan')
    journal['status'] = 'running'
    n = info['records']
    clone_old = dest / 'Transcripts' / 'records' / OLD

    def step(name, fn):
        entry = journal['steps'].setdefault(name, {})
        if 'finished_at' in entry:
            say('skip', f'{name}: already done')
            return
        entry['started_at'] = now()
        atomic(journal_path, encode(journal))
        entry['result'] = fn()
        entry['finished_at'] = now()
        atomic(journal_path, encode(journal))
        say('done', f'{name}: {entry["result"]}')

    def move():
        if ctx.old_dir.is_dir() and not ctx.new_dir.exists():
            os.rename(ctx.old_dir, ctx.new_dir)
            return 'renamed records/sotto -> records/transcriber'
        if ctx.new_dir.is_dir() and not ctx.old_dir.exists():
            return 'records/transcriber already in place (resumed)'
        raise Surprise('records/sotto and records/transcriber are in an unexpected state')

    def metadata():
        ids = sorted(p.name for p in ctx.new_dir.iterdir() if p.is_dir())
        expected = sorted(r.split('/')[0] for r in manifest['metadata'])
        if ids != expected:
            raise Surprise(f'record folders ({len(ids)}) differ from the backup ({len(expected)})')
        written = resumed = 0
        for rid in ids:
            p = ctx.new_dir / rid / 'metadata.json'
            raw = p.read_bytes()
            original = (clone_old / rid / 'metadata.json').read_bytes()
            if digest(clone_old / rid / 'metadata.json') != manifest['metadata'][f'{rid}/metadata.json']:
                raise Surprise(f'{rid}: backup metadata no longer matches its manifest hash')
            target = encode(transform(json.loads(original), OLD, NEW))
            if raw == original:
                atomic(p, target)
                written += 1
            elif raw == target:
                resumed += 1
            else:
                raise Surprise(f'{rid}: metadata.json changed since the backup')
        if written + resumed != n:
            raise Surprise('metadata count mismatch')
        return {'rewritten': written, 'already_done': resumed}

    def index():
        db = sqlite3.connect(ctx.index, isolation_level=None)
        try:
            db.execute('begin immediate')
            counts = index_counts(db)
            if counts.get(NEW) == n and OLD not in counts:
                db.execute('rollback')
                return 'already migrated (resumed)'
            if counts.get(OLD) != n or NEW in counts:
                raise Surprise(f'index counts {counts} unexpected')
            cur = db.execute("update records set key='transcriber/'||substr(key,7), source='transcriber', "
                             "path='records/transcriber/'||substr(path,15) where source='sotto' "
                             "and substr(key,1,6)='sotto/' and substr(path,1,14)='records/sotto/'")
            if cur.rowcount != n:
                raise Surprise(f'updated {cur.rowcount} rows, expected {n}')
            after = index_counts(db)
            if after.get(NEW) != n or OLD in after or after.get('wispr-flow') != info['wispr']:
                raise Surprise(f'index counts after update {after}')
            db.execute('commit')
            busy, log, done = db.execute('pragma wal_checkpoint(TRUNCATE)').fetchone()
            if busy:
                raise Surprise('WAL checkpoint was blocked by another connection')
            return {'updated_rows': n, 'counts': after, 'checkpointed_frames': done}
        except Exception:
            if db.in_transaction:
                db.execute('rollback')
            raise
        finally:
            db.close()

    def manifests():
        p = ctx.transcripts / 'dataset.json'
        before = p.read_bytes()
        d = json.loads(before)
        if d.get('sources') == ['wispr-flow', NEW]:
            return 'dataset.json already migrated (resumed)'
        if d.get('sources') != ['wispr-flow', OLD]:
            raise Surprise(f'dataset.json sources {d.get("sources")}')
        after = encode(dict(d, sources=['wispr-flow', NEW]))
        show_diff('dataset.json', before, after)
        atomic(p, after)
        return 'dataset.json sources updated; completeness.json and installation.json left as historical'

    def state():
        moved = dest / 'moved' / ctx.old_state.name
        if ctx.new_state.is_file() and not ctx.old_state.exists() and moved.is_file():
            return 'already migrated (resumed)'
        data = load_json(ctx.old_state)
        if data != load_json(dest / 'cache' / ctx.old_state.name):
            raise Surprise('sotto-state.json changed since the backup')
        keep = {k: v for k, v in data.items() if k.startswith(ctx.state_prefix)}
        if len(keep) != info['state_keep'] or len(keep) != n:
            raise Surprise(f'{len(keep)} current-repo state keys, expected {n}')
        atomic(ctx.new_state, encode(keep))
        moved.parent.mkdir(exist_ok=True)
        shutil.move(str(ctx.old_state), str(moved))
        return {'kept_keys': len(keep), 'dropped_stale_keys': len(data) - len(keep), 'old_state_moved_to': str(moved)}

    def config():
        before = ctx.config.read_bytes()
        cfg = json.loads(before)
        if 'transcriber_data' in cfg and 'sotto_data' not in cfg:
            return 'already migrated (resumed)'
        if 'sotto_data' not in cfg:
            raise Surprise(f'archive-config.json keys {sorted(cfg)}')
        new = {'archive_root': str(ctx.transcripts), 'transcriber_data': str(ctx.repo / '.local' / 'server'),
               'viewer_url': cfg.get('viewer_url', 'http://127.0.0.1:8392')}
        show_diff('archive-config.json', before, encode(new))
        atomic(ctx.config, encode(new))
        return 'archive-config.json written with transcriber_data'

    for name, fn in zip(STEPS, (move, metadata, index, manifests, state, config)):
        step(name, fn)
    journal['status'] = 'complete'
    journal['finished_at'] = now()
    atomic(journal_path, encode(journal))
    say('PASS', 'migration complete; run verify next')
    return 0


# ---------------------------------------------------------------- verify

def compare_trees(live, clone, label, quick):
    a, _ = walk(live)
    b, _ = walk(clone)
    if a != b:
        raise Surprise(f'{label}: file set differs from the clone ({len(a)} vs {len(b)})')
    rels = [r for r in a if r.endswith('metadata.json')] if quick else a
    x, total, sec = hash_many(live, rels, f'{label} live')
    y, _, _ = hash_many(clone, rels, f'{label} clone')
    wrong = [r for r in rels if x[r] != y[r]]
    if wrong:
        raise Surprise(f'{label}: {len(wrong)} files differ from the clone, e.g. {wrong[:3]}')
    say('ok', f'{label}: {len(a)} files, same set as clone; {len(rels)} hashed identical ({"metadata only" if quick else "full"})')


def verify_payload(base, manifest):
    rels, junk = walk(base)
    payload = sorted(r for r in rels if not is_meta(r))
    metas = sorted(r for r in rels if is_meta(r))
    if payload != sorted(manifest['files']) or metas != sorted(manifest['metadata']):
        extra = sorted(set(rels) - set(manifest['files']) - set(manifest['metadata']))
        missing = sorted((set(manifest['files']) | set(manifest['metadata'])) - set(rels))
        raise Surprise(f'file set differs from the backup manifest: extra {extra[:5]}, missing {missing[:5]}')
    hashes, total, _ = hash_many(base, payload, 'payload re-hash')
    wrong = [r for r in payload if hashes[r] != manifest['files'][r][1] or (base / r).stat().st_size != manifest['files'][r][0]]
    if wrong:
        raise Surprise(f'{len(wrong)} payload files differ from the backup manifest, e.g. {wrong[:3]}')
    say('ok', f'payload: {len(payload)} files ({total / 1e9:.2f} GB) match the backup manifest 100%; {len(metas)} metadata files present')
    return metas


def cmd_verify(ctx, args):
    dest, info, manifest = load_backup(ctx, args.backup)
    journal = load_json(dest / 'journal.json') if (dest / 'journal.json').exists() else {'status': 'none'}
    clone = dest / 'Transcripts'
    n, rolled = info['records'], args.rolled_back
    want = 'rolled-back' if rolled else 'complete'
    if journal['status'] != want:
        raise Surprise(f'journal status is {journal["status"]!r}, expected {want!r}')
    here, gone, src = (ctx.old_dir, ctx.new_dir, OLD) if rolled else (ctx.new_dir, ctx.old_dir, NEW)
    if gone.exists() or not here.is_dir():
        raise Surprise(f'expected {here} present and {gone} absent')

    metas = verify_payload(here, manifest)
    for rel in metas:
        current_raw = (here / rel).read_bytes()
        original_raw = (clone / 'records' / OLD / rel).read_bytes()
        if digest(clone / 'records' / OLD / rel) != manifest['metadata'][rel]:
            raise Surprise(f'{rel}: clone metadata differs from manifest')
        if rolled:
            if current_raw != original_raw:
                raise Surprise(f'{rel}: not restored byte-for-byte')
            continue
        current, original = json.loads(current_raw), json.loads(original_raw)
        changed = set(diff_paths(original, current))
        illegal = {p for p in changed if p not in ALLOWED_DIFFS and not ROLE_PATH.match(p)}
        if illegal or current != transform(original, OLD, NEW) or current_raw != encode(current):
            raise Surprise(f'{rel}: unexpected metadata differences {sorted(illegal) or "(bytes)"}')
    say('ok', f'metadata: {len(metas)} files ' + ('identical to backup' if rolled else
              'differ from backup only in source, selected_source and source_versions[].role'))

    db = ro(ctx.index)
    try:
        counts = index_counts(db)
        malformed = db.execute('select count(*) from records where path != \'records/\'||key '
                               'or substr(key,1,length(source)+1) != source||\'/\'').fetchone()[0]
        quick = db.execute('pragma quick_check').fetchone()[0]
    finally:
        db.close()
    if counts != {src: n, 'wispr-flow': info['wispr']} or malformed or quick != 'ok':
        raise Surprise(f'index counts {counts}, malformed rows {malformed}, quick_check {quick}')
    say('ok', f'index: {counts}, no malformed rows, quick_check ok')

    compare_trees(ctx.wispr_dir, clone / 'records' / 'wispr-flow', 'records/wispr-flow', args.wispr_quick)
    compare_trees(ctx.transcripts / 'sources', clone / 'sources', 'sources/', False)
    for p in sorted(clone.iterdir()):
        # verification.json is rewritten by every archive.py verify run, including the one below.
        if p.is_file() and p.name not in ('.DS_Store', 'verification.json'):
            live = (ctx.transcripts / p.name).read_bytes()
            if p.name == 'dataset.json' and not rolled:
                if json.loads(live) != dict(json.loads(p.read_bytes()), sources=['wispr-flow', NEW]):
                    raise Surprise('dataset.json differs beyond sources')
            elif live != p.read_bytes():
                raise Surprise(f'{p.name} differs from the clone')
    say('ok', 'top-level manifests identical to the clone' + ('' if rolled else ' except dataset.json sources')
        + ' (verification.json is regenerated below)')

    old_state_backup = (dest / 'cache' / ctx.old_state.name).read_bytes()
    if rolled:
        ok = (ctx.old_state.read_bytes() == old_state_backup and not ctx.new_state.exists()
              and ctx.config.read_bytes() == (dest / 'repo-local' / ctx.config.name).read_bytes())
    else:
        keep = {k: v for k, v in json.loads(old_state_backup).items() if k.startswith(ctx.state_prefix)}
        cfg = load_json(ctx.config)
        ok = (load_json(ctx.new_state) == keep and len(keep) == n and not ctx.old_state.exists()
              and cfg.get('transcriber_data') == str(ctx.repo / '.local' / 'server') and 'sotto_data' not in cfg)
    if not ok:
        raise Surprise('worker state or archive-config.json is not as expected')
    say('ok', 'worker state and archive-config.json as expected')

    started = time.monotonic()
    r = subprocess.run([sys.executable, str(HERE / 'archive.py'), '--root', str(ctx.transcripts),
                        '--cache', str(ctx.cache), 'verify'], capture_output=True, text=True)
    if r.returncode:
        raise Surprise('archive.py verify failed: ' + r.stderr.strip()[-500:])
    result = json.loads(r.stdout)
    if not result.get('passed') or result.get('records') != n + info['wispr']:
        raise Surprise(f'archive.py verify result {result}')
    say('ok', f'archive.py verify passed: {result["records"]} records, {result["verified_bytes"] / 1e9:.2f} GB '
              f'in {time.monotonic() - started:.0f}s (wrote verification.json)')
    journal['rolled_back_verified_at' if rolled else 'verified_at'] = now()
    atomic(dest / 'journal.json', encode(journal))
    say('PASS', 'rolled-back state verified' if rolled else 'migration verified; migrate-sotto-launchd.sh up may run')
    return 0


# ---------------------------------------------------------------- rollback

def cmd_rollback(ctx, args):
    dest, info, manifest = load_backup(ctx, args.backup)
    journal_path = dest / 'journal.json'
    journal = load_json(journal_path) if journal_path.exists() else {'status': 'none', 'steps': {}}
    require_stopped(ctx)
    clone = dest / 'Transcripts'
    clone_old = clone / 'records' / OLD
    displaced = dest / 'rollback-displaced' / datetime.now().strftime('%Y%m%d-%H%M%S')

    def displace(p):
        if p.exists():
            target = displaced / p.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(p), str(target))
            say('did', f'moved {p} -> {target}')

    if ctx.new_dir.is_dir():
        if ctx.old_dir.exists():
            raise Surprise('both records/sotto and records/transcriber exist; resolve by hand')
        os.rename(ctx.new_dir, ctx.old_dir)
        say('did', 'renamed records/transcriber -> records/sotto')

    restored = converted = 0
    for d in sorted(p for p in ctx.old_dir.iterdir() if p.is_dir()):
        rel = f'{d.name}/metadata.json'
        p = d / rel.split('/')[1]
        if rel in manifest['metadata']:
            original = (clone_old / rel).read_bytes()
            if digest(clone_old / rel) != manifest['metadata'][rel]:
                raise Surprise(f'{rel}: clone metadata differs from its manifest; restore by hand')
            if p.read_bytes() != original:
                atomic(p, original)
                restored += 1
        else:  # recorded after the migration: keep it, rename it back
            atomic(p, encode(transform(load_json(p), NEW, OLD)))
            converted += 1
            say('did', f'{d.name}: new record kept and converted back to sotto')
    say('did', f'metadata restored from backup: {restored}; post-migration records converted: {converted}')

    present = set(walk(ctx.old_dir)[0])
    missing = [r for r in manifest['files'] if r not in present]
    hashes, _, _ = hash_many(ctx.old_dir, [r for r in manifest['files'] if r in present], 'rollback payload check')
    damaged = [r for r, sha in hashes.items() if sha != manifest['files'][r][1]]
    for r in missing + damaged:
        target = ctx.old_dir / r
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            displace(target)
        subprocess.run(['cp', '-c', '-p', str(clone_old / r), str(target)], check=True)
    extra = sorted(present - set(manifest['files']) - set(manifest['metadata']))
    say('did', f'payload: {len(missing)} missing + {len(damaged)} damaged files restored from clone; '
               f'{len(extra)} newer files kept in place')

    for suffix in ('-wal', '-shm'):
        displace(ctx.cache / ('index.sqlite' + suffix))
    tmp = ctx.cache / '.index.sqlite-restore'
    shutil.copy2(dest / 'cache' / 'index.sqlite', tmp)
    os.replace(tmp, ctx.index)
    say('did', 'index.sqlite restored from the sqlite backup')

    displace(ctx.new_state)
    if not ctx.old_state.exists():
        copy_exact(dest / 'cache' / ctx.old_state.name, ctx.old_state)
    elif ctx.old_state.read_bytes() != (dest / 'cache' / ctx.old_state.name).read_bytes():
        displace(ctx.old_state)
        copy_exact(dest / 'cache' / ctx.old_state.name, ctx.old_state)
    copy_exact(dest / 'repo-local' / ctx.config.name, ctx.config)
    say('did', 'sotto-state.json and archive-config.json restored')

    for p in sorted(clone.iterdir()):
        if p.is_file() and p.name != '.DS_Store':
            live = ctx.transcripts / p.name
            if not live.is_file() or live.read_bytes() != p.read_bytes():
                atomic(live, p.read_bytes())
                say('did', f'restored {p.name} from clone')
    journal['status'] = 'rolled-back'
    journal['rolled_back_at'] = now()
    atomic(journal_path, encode(journal))
    say('PASS', 'archive rolled back; run `verify --rolled-back`, then migrate-sotto-launchd.sh rollback')
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--transcripts', default=str(Path.home() / 'Transcripts'))
    p.add_argument('--repo', default=None, help='main checkout (default: from git)')
    p.add_argument('--cache', default=None, help='default: <repo>/.local/archive-cache')
    p.add_argument('--launch-agents', default=str(Path.home() / 'Library/LaunchAgents'))
    p.add_argument('--unsafe-skip-service-check', action='store_true', help='scratch rehearsals only; refused for real data')
    sub = p.add_subparsers(dest='command', required=True)
    s = sub.add_parser('plan')
    s.add_argument('--measure-mb', type=int, default=0, help='hash this many MB to estimate throughput')
    s = sub.add_parser('backup')
    s.add_argument('--dest', required=True)
    s = sub.add_parser('migrate')
    s.add_argument('--backup', required=True)
    s = sub.add_parser('verify')
    s.add_argument('--backup', required=True)
    s.add_argument('--rolled-back', action='store_true')
    s.add_argument('--wispr-quick', action='store_true', help='compare only wispr-flow metadata hashes')
    s = sub.add_parser('rollback')
    s.add_argument('--backup', required=True)
    args = p.parse_args()
    args.repo = args.repo or str(main_repo())
    os.umask(0o077)
    ctx = Ctx(args)
    try:
        return {'plan': cmd_plan, 'backup': cmd_backup, 'migrate': cmd_migrate, 'verify': cmd_verify,
                'rollback': cmd_rollback}[args.command](ctx, args)
    except Surprise as e:
        say('FAIL', str(e))
        return 2
    except Exception as e:  # journal keeps the finished steps; rerunning the same command resumes or rolls back
        say('FAIL', f'{type(e).__name__}: {e}')
        return 3


if __name__ == '__main__':
    sys.exit(main())
