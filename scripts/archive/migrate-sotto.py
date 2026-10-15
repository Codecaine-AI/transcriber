#!/usr/bin/env python3
"""One-off move of the transcript archive from the `sotto` source id to `transcriber`.

Subcommands, in order: plan (read-only), backup, migrate, verify; rollback only while frozen.
drain-status is the read-only probe migrate-sotto-launchd.sh polls before stopping services.

Only three metadata.json fields change (source, selected_source, source_versions[].role), plus
dataset.json's source list, the search index, the worker state file and archive-config.json.
Every other path under the archive must stay byte-identical; backup, verify and rollback prove it
against a complete typed inventory of the whole archive.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import difflib
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from archive import digest, encode, safe_id  # noqa: E402  (the worker's own byte encoding)

OLD, NEW = 'sotto', 'transcriber'
LABELS = ('server', 'archive', 'app')
PORTS = (8391, 8392)
STEPS = ('move', 'metadata', 'index', 'manifests', 'state', 'config', 'after-manifest')
IN_FLIGHT = ('receiving', 'queued', 'transcribing', 'proofreading')
ROLE_PATH = re.compile(r'^\.source_versions\[\d+\]\.role$')
UUID_DIR = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
TEMP_FILE = re.compile(r'^\..+-[a-z0-9_]{8}$')  # tempfile.mkstemp(prefix='.' + name + '-')
UNSTABLE = 'verification.json'  # rewritten by every archive.py verify run; compared by type and mode only
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


class Ctx:
    def __init__(self, args):
        self.transcripts = Path(args.transcripts).expanduser().resolve()
        self.repo = Path(args.repo).expanduser().resolve()
        self.cache = Path(args.cache).expanduser().resolve() if args.cache else self.repo / '.local' / 'archive-cache'
        self.agents = Path(args.launch_agents).expanduser().resolve()
        self.local = self.repo / '.local'
        self.config = self.local / 'archive-config.json'
        self.generations = self.local / 'server' / 'generations'
        self.records = self.transcripts / 'records'
        self.old_dir, self.new_dir = self.records / OLD, self.records / NEW
        self.index = self.cache / 'index.sqlite'
        self.old_state, self.new_state = self.cache / f'{OLD}-state.json', self.cache / f'{NEW}-state.json'
        self.state_prefix = str(self.generations) + '/'
        self.skip_services = getattr(args, 'unsafe_skip_service_check', False)
        real = main_repo()
        is_real = (self.transcripts == (Path.home() / 'Transcripts').resolve() or self.repo == real
                   or self.cache.is_relative_to(real) or self.agents == (Path.home() / 'Library/LaunchAgents').resolve())
        if self.skip_services and is_real:
            raise SystemExit('--unsafe-skip-service-check is refused for the real archive, repo, cache or LaunchAgents.')


# ---------------------------------------------------------------- durable file operations

def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write(path, data, mode=0o600):
    """archive.atomic() plus an explicit mode and a parent-directory fsync."""
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fchmod(f.fileno(), mode)
            os.fsync(f.fileno())
        os.replace(name, path)
        fsync_dir(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def rename(src, dst):
    os.rename(src, dst)
    fsync_dir(Path(dst).parent)
    if Path(src).parent != Path(dst).parent:
        fsync_dir(Path(src).parent)


def unlink(path):
    os.unlink(path)
    fsync_dir(Path(path).parent)


def load_json(path):
    return json.loads(Path(path).read_text())


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- inventory

def inventory(base, hashed=True, label=None):
    """Typed entry for every path under base: d(mode), f(mode,size,sha), l(target). Special files refuse."""
    started = time.monotonic()
    entries = {}
    for root, dirs, names in os.walk(base):
        dirs.sort()
        for name in sorted(dirs) + sorted(names):
            p = os.path.join(root, name)
            rel = os.path.relpath(p, base)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                entries[rel] = {'t': 'l', 'target': os.readlink(p)}
            elif stat.S_ISDIR(st.st_mode):
                entries[rel] = {'t': 'd', 'mode': stat.S_IMODE(st.st_mode)}
            elif stat.S_ISREG(st.st_mode):
                entries[rel] = {'t': 'f', 'mode': stat.S_IMODE(st.st_mode), 'size': st.st_size}
            else:
                raise Surprise(f'special file in the archive: {p}')
    if hashed:
        files = [r for r, e in entries.items() if e['t'] == 'f']
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            for rel, sha in zip(files, pool.map(lambda r: digest(os.path.join(base, r)), files)):
                entries[rel]['sha'] = sha
        total = sum(entries[r]['size'] for r in files)
        sec = time.monotonic() - started
        say('time', f'{label or base}: {len(entries)} entries, {len(files)} files, {total / 1e9:.2f} GB hashed '
                    f'in {sec:.1f}s')
    return entries


def save_inventory(path, entries):
    write(path, json.dumps(entries, sort_keys=True, separators=(',', ':')).encode())


def diff_inventories(a, b, relax=(UNSTABLE,)):
    """Paths whose entries differ. Paths in relax compare by type and mode only."""
    out = []
    for rel in sorted(set(a) | set(b)):
        x, y = a.get(rel), b.get(rel)
        if x is None or y is None:
            out.append(f'{"extra" if x is None else "missing"}: {rel}')
        elif rel in relax:
            if (x['t'], x.get('mode')) != (y['t'], y.get('mode')):
                out.append(f'type/mode: {rel}')
        elif x != y:
            out.append(f'changed: {rel}')
    return out


def rename_rel(rel):
    return re.sub(r'^records/sotto(?=/|$)', 'records/transcriber', rel)


TEMP_NAMES = ('metadata.json', 'dataset.json', 'verification.json', f'{OLD}-state.json', f'{NEW}-state.json',
              'archive-config.json', 'journal.json', 'backup.json', 'after.json', 'inventory-after.json')


def clean_temp_files(ctx, known, dest):
    """After a crash, remove only our own mkstemp leftovers ('.<name>-xxxxxxxx') that the backup never saw."""
    dirs = [ctx.transcripts, ctx.cache, ctx.local, dest]
    for d in (ctx.new_dir, ctx.old_dir):
        if d.is_dir():
            dirs += [x for x in d.iterdir() if x.is_dir()]
    for d in dirs:
        for p in d.iterdir():
            if not (p.is_file() and TEMP_FILE.match(p.name) and p.name[1:-9] in TEMP_NAMES):
                continue
            rel = os.path.relpath(p, ctx.transcripts)
            if rel in known or rel.replace(f'records/{NEW}/', f'records/{OLD}/', 1) in known:
                continue
            unlink(p)
            say('did', f'removed leftover temp file {p}')


# ---------------------------------------------------------------- metadata transform

def transform(m, frm, to):
    roles = [v.get('role') for v in m.get('source_versions', [])]
    if m.get('source') != frm or m.get('selected_source') != frm or any(r != frm + '-metadata' for r in roles):
        raise Surprise(f'{m.get("id")}: expected {frm!r} source fields and {frm}-metadata roles, found '
                       f'{m.get("source")!r}/{m.get("selected_source")!r}/{sorted(set(roles))}')
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
    for line in difflib.unified_diff(before.decode().splitlines(), after.decode().splitlines(),
                                     f'a/{name}', f'b/{name}', lineterm='', n=1):
        print('    ' + line)


# ---------------------------------------------------------------- index, services, drain

def ro(path):
    return sqlite3.connect(Path(path).as_uri() + '?mode=ro', uri=True)


def index_counts(db):
    return dict(db.execute('select source, count(*) from records group by source').fetchall())


def index_digest(path):
    db = ro(path)
    try:
        h = hashlib.sha256()
        for row in db.execute('select key,source,timestamp,status,app,raw,clean,path,audio,screenshot,bytes '
                              'from records order by key'):
            h.update(json.dumps(row, ensure_ascii=False).encode() + b'\n')
        return h.hexdigest(), index_counts(db)
    finally:
        db.close()


def services():
    uid = os.getuid()
    loaded = {f'ai.codecaine.{p}.{x}': subprocess.run(['launchctl', 'print', f'gui/{uid}/ai.codecaine.{p}.{x}'],
                                                      capture_output=True).returncode == 0
              for p in (OLD, NEW) for x in LABELS}
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


def drain(ctx, namespace):
    """Server takes not yet terminal, and finished takes the archive worker has not copied yet."""
    state_path = ctx.cache / f'{namespace}-state.json'
    state = load_json(state_path) if state_path.exists() else {}
    receiving, in_flight, unarchived, unreadable = [], [], [], []
    for path in sorted(ctx.generations.glob('*/metadata.json')):
        try:
            m = load_json(path)
        except (OSError, ValueError):
            unreadable.append(path.parent.name)
            continue
        st = path.stat()
        if m.get('status') == 'receiving':
            receiving.append(path.parent.name)
        if m.get('status') in IN_FLIGHT:
            in_flight.append(path.parent.name)
        elif not m.get('importedSource') and (
                state.get(str(path)) != [st.st_mtime_ns, st.st_size]
                or not (ctx.records / namespace / safe_id(path.parent.name) / 'metadata.json').exists()):
            unarchived.append(path.parent.name)
    return {'receiving': len(receiving), 'in_flight': len(in_flight), 'unarchived': len(unarchived),
            'unreadable': len(unreadable), 'examples': (receiving + in_flight + unarchived + unreadable)[:5]}


# ---------------------------------------------------------------- inspection

def inspect(ctx, plists):
    """Read-only survey; collects surprises instead of raising."""
    s, f = [], {}

    def surprise(text):
        s.append(text)
        say('SURPRISE', text)

    ds = ctx.transcripts / 'dataset.json'
    if not ds.is_file() or load_json(ds).get('format') != 'codecaine-transcripts':
        surprise(f'{ds} is missing or not a codecaine-transcripts dataset')
        return f, s
    entries = sorted(p.name for p in ctx.records.iterdir())
    if [e for e in entries if e != '.DS_Store'] != [OLD, 'wispr-flow']:
        surprise(f'records/ holds {entries}; expected exactly sotto and wispr-flow')
    if not ctx.old_dir.is_dir():
        return f, s

    ids = []
    for p in sorted(ctx.old_dir.iterdir()):
        if p.is_dir() and not p.is_symlink() and UUID_DIR.match(p.name):
            ids.append(p.name)
        else:
            surprise(f'unexpected entry in records/sotto: {p.name}')
    f['records'] = n = len(ids)
    say('ok', f'records/sotto: {n} record folders')
    roles, versions, bad = {}, 0, 0
    for rid in ids:
        p = ctx.old_dir / rid / 'metadata.json'
        try:
            raw = p.read_bytes()
            m = json.loads(raw)
            if m.get('id') != rid or encode(m) != raw:
                raise Surprise(f'{rid}: metadata id or byte encoding is not as the worker writes it')
            transform(m, OLD, NEW)
            for v in m['source_versions']:
                roles[v['role']] = roles.get(v['role'], 0) + 1
                versions += 1
        except (Surprise, ValueError, OSError) as e:
            bad += 1
            if bad <= 5:
                surprise(str(e))
    if not bad:
        say('change', f'{n} metadata.json: source, selected_source sotto->transcriber; {versions} source_versions '
                      f'roles {roles} -> transcriber-metadata')
    f['wispr'] = wispr = sum(1 for p in (ctx.records / 'wispr-flow').iterdir() if p.is_dir())
    say('ok', f'records/wispr-flow: {wispr} record folders (untouched)')

    if not ctx.index.is_file():
        surprise(f'{ctx.index} is missing')
    else:
        db = ro(ctx.index)
        try:
            counts = index_counts(db)
            bad_rows = db.execute("select count(*) from records where path != 'records/'||key or "
                                  "substr(key,1,length(source)+1) != source||'/'").fetchone()[0]
            index_ids = sorted(r[0] for r in db.execute("select substr(key,7) from records where source='sotto'"))
        finally:
            db.close()
        f['index_counts'] = counts
        if counts != {OLD: n, 'wispr-flow': wispr} or bad_rows or index_ids != ids:
            surprise(f'index {counts} ({bad_rows} malformed rows) does not match folders (sotto {n}, wispr-flow {wispr})')
        else:
            say('change', f'index: UPDATE {n} rows sotto->transcriber; {wispr} wispr-flow rows unchanged')

    if ctx.new_state.exists():
        surprise(f'{ctx.new_state} already exists')
    if not ctx.old_state.is_file():
        surprise(f'{ctx.old_state} is missing')
    else:
        state = load_json(ctx.old_state)
        keep = {k for k in state if k.startswith(ctx.state_prefix)}
        f['state_keep'] = len(keep)
        if sorted({Path(k).parent.name.lower() for k in keep}) != ids:
            surprise(f'state: {len(keep)} keys under {ctx.state_prefix} do not match the {n} record ids')
        else:
            say('change', f'state: {NEW}-state.json keeps {len(keep)} keys, drops {len(state) - len(keep)} stale keys')

    if not ctx.config.is_file() or 'sotto_data' not in load_json(ctx.config):
        surprise(f'{ctx.config} is missing or has no sotto_data key')
    else:
        say('change', f'archive-config.json: sotto_data -> transcriber_data={str(ctx.local / "server")!r}')

    for p in sorted(ctx.transcripts.iterdir()):
        if not p.is_file() or 'sotto' not in p.read_text(errors='replace').lower():
            continue
        if p.name == 'dataset.json':
            d = load_json(p)
            if encode(d) != p.read_bytes() or d.get('sources') != ['wispr-flow', OLD]:
                surprise('dataset.json is not as expected')
            else:
                say('change', 'dataset.json sources ["wispr-flow","sotto"] -> ["wispr-flow","transcriber"]')
        elif p.name in ('completeness.json', 'installation.json'):
            say('keep', f'{p.name}: historical paths/keys only, unchanged by Phase 1')
        else:
            surprise(f'{p.name} mentions sotto; not handled by this tool')

    links = [r for r, e in inventory(ctx.transcripts, hashed=False).items() if e['t'] == 'l']
    if links:
        surprise(f'{len(links)} symbolic links in the archive, e.g. {links[:3]}')
    for label in LABELS:
        if not (plists / f'ai.codecaine.{OLD}.{label}.plist').is_file():
            surprise(f'missing {plists}/ai.codecaine.{OLD}.{label}.plist')
    if list(ctx.agents.glob(f'ai.codecaine.{NEW}.*.plist')):
        surprise('transcriber plists are already installed')
    loaded, ports = services()
    say('info', f'launchd loaded: {[k for k, v in loaded.items() if v] or "none"}; listening: '
                f'{ {p: w or "closed" for p, w in ports.items()} }')
    d = drain(ctx, OLD)
    say('info', f'server/worker: {d}')
    usage = shutil.disk_usage(ctx.transcripts)
    if usage.free < 10 * 1024 ** 3:
        surprise(f'free space {usage.free / 1e9:.1f} GB < 10 GB')
    else:
        say('ok', f'free space {usage.free / 1e9:.0f} GB')
    return f, s


def cmd_plan(ctx, args):
    say('info', f'transcripts={ctx.transcripts} cache={ctx.cache} repo={ctx.repo}')
    _, s = inspect(ctx, ctx.agents)
    code = (ctx.repo / 'scripts/archive/archive.py').read_text()
    say('info', 'main checkout archive.py: ' + ('new transcriber code' if "'--transcriber-data'" in code
                                               else 'old sotto code (merge before launchd up)'))
    if s:
        say('FAIL', f'{len(s)} surprise(s)')
        return 1
    say('PASS', 'plan found nothing unexpected')
    return 0


def cmd_drain_status(ctx, args):
    d = drain(ctx, args.namespace)
    print(json.dumps(d), flush=True)
    return 0 if not (d['in_flight'] or d['unarchived'] or d['unreadable']) else 1


# ---------------------------------------------------------------- backup

def cmd_backup(ctx, args):
    dest = Path(args.dest).expanduser().resolve()
    plists = dest / 'launchd' / 'LaunchAgents'
    leftovers = sorted(p.name for p in dest.iterdir()) if dest.exists() else []
    if [x for x in leftovers if x not in ('launchd', 'down.log')]:
        raise Surprise(f'{dest} holds {leftovers}; it may only contain launchd/ from migrate-sotto-launchd.sh down')
    for inside in (ctx.transcripts, ctx.cache):
        if dest == inside or dest.is_relative_to(inside):
            raise Surprise(f'the backup must live outside {inside}')
    if list(ctx.agents.glob(f'ai.codecaine.{OLD}.*.plist')):
        raise Surprise('sotto plists are still in LaunchAgents; run migrate-sotto-launchd.sh down --dir DEST first')
    require_stopped(ctx)
    f, s = inspect(ctx, plists)
    if s:
        raise Surprise(f'{len(s)} precondition(s) failed; run plan')
    dest.mkdir(parents=True, exist_ok=True)
    if dest.stat().st_dev != ctx.transcripts.stat().st_dev:
        raise Surprise('the backup must be on the archive volume so cp -c can clone')

    started = time.monotonic()
    before = inventory(ctx.transcripts, label='live archive')
    clone = dest / 'Transcripts'
    t = time.monotonic()
    subprocess.run(['cp', '-c', '-p', '-R', str(ctx.transcripts), str(clone)], check=True)
    say('time', f'APFS clone in {time.monotonic() - t:.1f}s')
    cloned = inventory(clone, label='clone')
    problems = diff_inventories(before, cloned, relax=())
    if problems:
        raise Surprise(f'clone differs from the live archive: {problems[:5]}')
    again = inventory(ctx.transcripts, hashed=False)
    if diff_inventories({k: {x: y for x, y in v.items() if x != 'sha'} for k, v in before.items()}, again, relax=()):
        raise Surprise('the live archive changed while it was being backed up')
    say('ok', f'clone: all {len(cloned)} entries match the live archive (every file hashed on both sides)')
    save_inventory(dest / 'inventory-before.json', before)

    (dest / 'cache').mkdir()
    src, dst = ro(ctx.index), sqlite3.connect(dest / 'cache' / 'index.sqlite')
    try:
        src.backup(dst)
    finally:
        src.close()
        dst.close()
    pre_digest, counts = index_digest(ctx.index)
    if index_digest(dest / 'cache' / 'index.sqlite')[0] != pre_digest:
        raise Surprise('index snapshot differs from the live index')
    (dest / 'repo-local').mkdir()
    for src_path, dst_path in ((ctx.old_state, dest / 'cache' / ctx.old_state.name),
                               (ctx.config, dest / 'repo-local' / ctx.config.name)):
        shutil.copy2(src_path, dst_path)
        if digest(src_path) != digest(dst_path):
            raise Surprise(f'copy of {src_path} differs')
    info = {'status': 'complete', 'created_at': now(), 'transcripts': str(ctx.transcripts), 'cache': str(ctx.cache),
            'repo': str(ctx.repo), 'launch_agents': str(ctx.agents), 'records': f['records'], 'wispr': f['wispr'],
            'state_keep': f['state_keep'], 'index_digest': pre_digest, 'index_counts': counts,
            'state_sha': digest(ctx.old_state), 'config_sha': digest(ctx.config),
            'launchd': {p.name: digest(p) for p in sorted(plists.iterdir())}}
    write(dest / 'backup.json', encode(info))
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
    journal_path = dest / 'journal.json'
    journal = load_json(journal_path) if journal_path.exists() else {'status': 'new', 'steps': {}}
    return dest, info, load_json(dest / 'inventory-before.json'), journal_path, journal


def frozen_state(ctx):
    digest_now, counts = index_digest(ctx.index)
    return {'index_digest': digest_now, 'index_counts': counts,
            'state_sha': digest(ctx.new_state) if ctx.new_state.exists() else None,
            'config_sha': digest(ctx.config)}


# ---------------------------------------------------------------- migrate

def cmd_migrate(ctx, args):
    dest, info, before, journal_path, journal = load_backup(ctx, args.backup)
    if journal['status'] != 'new' and journal['status'] != 'running':
        raise Surprise(f'migration is {journal["status"]} for this backup; refusing to run again')
    require_stopped(ctx)
    if journal['status'] == 'running':
        say('info', f'resuming; finished: {[k for k, v in journal["steps"].items() if "finished_at" in v]}')
        clean_temp_files(ctx, before, dest)
    else:
        _, s = inspect(ctx, dest / 'launchd' / 'LaunchAgents')
        if s:
            raise Surprise(f'{len(s)} precondition(s) failed; run plan')
        shape = {k: {x: y for x, y in v.items() if x != 'sha'} for k, v in before.items()}
        problems = diff_inventories(shape, inventory(ctx.transcripts, hashed=False), relax=())
        if problems:
            raise Surprise(f'archive changed since the backup: {problems[:5]}')
    journal['status'] = 'running'
    n = info['records']
    clone_old = dest / 'Transcripts' / 'records' / OLD

    def step(name, fn):
        entry = journal['steps'].setdefault(name, {})
        if 'finished_at' in entry:
            say('skip', f'{name}: already done')
            return
        entry['started_at'] = now()
        write(journal_path, encode(journal))
        entry['result'] = fn()
        entry['finished_at'] = now()
        write(journal_path, encode(journal))
        say('done', f'{name}: {entry["result"]}')

    def move():
        if ctx.old_dir.is_dir() and not ctx.new_dir.exists():
            rename(ctx.old_dir, ctx.new_dir)
            return 'renamed records/sotto -> records/transcriber'
        if ctx.new_dir.is_dir() and not ctx.old_dir.exists():
            return 'already in place (resumed)'
        raise Surprise('records/sotto and records/transcriber are in an unexpected state')

    def metadata():
        written = resumed = 0
        for rel, e in sorted(before.items()):
            if not re.fullmatch(r'records/sotto/[^/]+/metadata\.json', rel):
                continue
            rid = rel.split('/')[2]
            p = ctx.new_dir / rid / 'metadata.json'
            original = (clone_old / rid / 'metadata.json').read_bytes()
            if sha_bytes(original) != e['sha']:
                raise Surprise(f'{rid}: clone metadata no longer matches the inventory')
            target = encode(transform(json.loads(original), OLD, NEW))
            raw = p.read_bytes()
            if raw == original:
                write(p, target, e['mode'])
                written += 1
            elif raw == target:
                resumed += 1
            else:
                raise Surprise(f'{rid}: metadata.json changed since the backup')
        if written + resumed != n:
            raise Surprise(f'{written + resumed} metadata files, expected {n}')
        return {'rewritten': written, 'already_done': resumed}

    def index():
        db = sqlite3.connect(ctx.index, isolation_level=None)
        try:
            db.execute('begin immediate')
            counts = index_counts(db)
            if counts == {NEW: n, 'wispr-flow': info['wispr']}:
                db.execute('rollback')
                return 'already migrated (resumed)'
            if counts != {OLD: n, 'wispr-flow': info['wispr']}:
                raise Surprise(f'index counts {counts}')
            cur = db.execute("update records set key='transcriber/'||substr(key,7), source='transcriber', "
                             "path='records/transcriber/'||substr(path,15) where source='sotto' "
                             "and substr(key,1,6)='sotto/' and substr(path,1,14)='records/sotto/'")
            if cur.rowcount != n or index_counts(db) != {NEW: n, 'wispr-flow': info['wispr']}:
                raise Surprise('index update touched an unexpected number of rows')
            db.execute('commit')
            if db.execute('pragma wal_checkpoint(TRUNCATE)').fetchone()[0]:
                raise Surprise('WAL checkpoint was blocked by another connection')
            return {'updated_rows': n}
        except Exception:
            if db.in_transaction:
                db.execute('rollback')
            raise
        finally:
            db.close()

    def manifests():
        p = ctx.transcripts / 'dataset.json'
        raw = p.read_bytes()
        d = json.loads(raw)
        if d.get('sources') == ['wispr-flow', NEW]:
            return 'already migrated (resumed)'
        if d.get('sources') != ['wispr-flow', OLD]:
            raise Surprise(f'dataset.json sources {d.get("sources")}')
        after = encode(dict(d, sources=['wispr-flow', NEW]))
        show_diff('dataset.json', raw, after)
        write(p, after, before['dataset.json']['mode'])
        return 'dataset.json sources updated'

    def state():
        if ctx.new_state.is_file() and not ctx.old_state.exists():
            return 'already migrated (resumed)'
        if digest(ctx.old_state) != info['state_sha']:
            raise Surprise('sotto-state.json changed since the backup')
        keep = {k: v for k, v in load_json(ctx.old_state).items() if k.startswith(ctx.state_prefix)}
        if len(keep) != n:
            raise Surprise(f'{len(keep)} current-repo state keys, expected {n}')
        write(ctx.new_state, encode(keep))
        unlink(ctx.old_state)  # its exact bytes are in the backup (state_sha)
        return {'kept_keys': len(keep)}

    def config():
        raw = ctx.config.read_bytes()
        cfg = json.loads(raw)
        if 'transcriber_data' in cfg and 'sotto_data' not in cfg:
            return 'already migrated (resumed)'
        if digest(ctx.config) != info['config_sha']:
            raise Surprise('archive-config.json changed since the backup')
        new = {'archive_root': str(ctx.transcripts), 'transcriber_data': str(ctx.local / 'server'),
               'viewer_url': cfg.get('viewer_url', 'http://127.0.0.1:8392')}
        show_diff('archive-config.json', raw, encode(new))
        write(ctx.config, encode(new))
        return 'archive-config.json uses transcriber_data'

    def after_manifest():
        # The frozen post-migration state; rollback is allowed only while the live data still equals it.
        save_inventory(dest / 'inventory-after.json', inventory(ctx.transcripts, label='migrated archive'))
        write(dest / 'after.json', encode(frozen_state(ctx)))
        return 'wrote inventory-after.json and after.json'

    for name, fn in zip(STEPS, (move, metadata, index, manifests, state, config, after_manifest)):
        step(name, fn)
    journal['status'] = 'complete'
    journal['finished_at'] = now()
    write(journal_path, encode(journal))
    say('PASS', 'migration complete; run verify next')
    return 0


# ---------------------------------------------------------------- verify

def check_transformed(ctx, dest, before, after):
    """after must equal before with records/sotto renamed, apart from the intended metadata fields."""
    expected = {rename_rel(r): e for r, e in before.items()}
    problems = []
    for rel in sorted(set(expected) | set(after)):
        x, y = expected.get(rel), after.get(rel)
        if x is None or y is None:
            problems.append(f'{"extra" if x is None else "missing"}: {rel}')
        elif rel == UNSTABLE:
            if (x['t'], x['mode']) != (y['t'], y['mode']):
                problems.append(f'type/mode: {rel}')
        elif rel == 'dataset.json' or re.fullmatch(r'records/transcriber/[^/]+/metadata\.json', rel):
            if (x['t'], x['mode']) != (y['t'], y['mode']):
                problems.append(f'type/mode: {rel}')
                continue
            old = json.loads((dest / 'Transcripts' / [r for r in (rel, rel.replace(NEW, OLD, 1)) if r in before][0])
                             .read_bytes())
            live = (ctx.transcripts / rel).read_bytes()
            if sha_bytes(live) != y['sha']:
                problems.append(f'changed since after-manifest: {rel}')
            elif rel == 'dataset.json':
                if json.loads(live) != dict(old, sources=['wispr-flow', NEW]) or encode(json.loads(live)) != live:
                    problems.append('dataset.json differs beyond sources')
            else:
                cur = json.loads(live)
                illegal = {p for p in diff_paths(old, cur) if p not in ('.source', '.selected_source')
                           and not ROLE_PATH.match(p)}
                if illegal or cur != transform(old, OLD, NEW) or encode(cur) != live:
                    problems.append(f'{rel}: unexpected differences {sorted(illegal) or "(bytes)"}')
        elif x != y:
            problems.append(f'changed: {rel}')
    return problems


def cmd_verify(ctx, args):
    dest, info, before, journal_path, journal = load_backup(ctx, args.backup)
    if journal['status'] != 'complete':
        raise Surprise(f'journal status is {journal["status"]!r}, expected complete')
    after = load_json(dest / 'inventory-after.json')
    live = inventory(ctx.transcripts, label='live archive')
    problems = diff_inventories(after, live)
    if problems:
        raise Surprise(f'live archive differs from the post-migration manifest: {problems[:5]}')
    say('ok', f'live archive equals the post-migration manifest ({len(live)} entries)')
    problems = check_transformed(ctx, dest, before, after)
    if problems:
        raise Surprise(f'{len(problems)} unexpected differences from the backup: {problems[:5]}')
    say('ok', f'every path equals the backup; only records/sotto -> records/transcriber, {info["records"]} metadata '
              'files (source, selected_source, roles) and dataset.json sources changed')

    frozen = load_json(dest / 'after.json')
    current = frozen_state(ctx)
    db = ro(ctx.index)
    try:
        quick = db.execute('pragma quick_check').fetchone()[0]
    finally:
        db.close()
    if current != frozen or frozen['index_counts'] != {NEW: info['records'], 'wispr-flow': info['wispr']} or quick != 'ok':
        raise Surprise(f'index/state/config differ from the post-migration manifest: {current}')
    keep = {k: v for k, v in json.loads((dest / 'cache' / ctx.old_state.name).read_bytes()).items()
            if k.startswith(ctx.state_prefix)}
    cfg = load_json(ctx.config)
    if (load_json(ctx.new_state) != keep or ctx.old_state.exists() or 'sotto_data' in cfg
            or cfg.get('transcriber_data') != str(ctx.local / 'server')):
        raise Surprise('worker state or archive-config.json is not as expected')
    say('ok', f'index {current["index_counts"]} quick_check ok; state ({len(keep)} keys) and config as expected')

    started = time.monotonic()
    r = subprocess.run([sys.executable, str(HERE / 'archive.py'), '--root', str(ctx.transcripts),
                        '--cache', str(ctx.cache), 'verify'], capture_output=True, text=True)
    result = json.loads(r.stdout) if r.returncode == 0 else {}
    if not result.get('passed') or result.get('records') != info['records'] + info['wispr']:
        raise Surprise('archive.py verify failed: ' + (r.stderr.strip()[-500:] or str(result)))
    say('ok', f'archive.py verify: {result["records"]} records, {result["verified_bytes"] / 1e9:.2f} GB in '
              f'{time.monotonic() - started:.0f}s')
    journal['verified_at'] = now()
    write(journal_path, encode(journal))
    say('PASS', 'migration verified; migrate-sotto-launchd.sh up may run')
    return 0


# ---------------------------------------------------------------- rollback (exact, frozen only)

FIX_FORWARD = '''Rollback is refused: the archive changed after migration ({why}).
Restoring the pre-migration snapshot now would discard that newer data. The only supported path is fix-forward:
  1. Keep the new code and start the transcriber services again: migrate-sotto-launchd.sh start --dir DIR.
  2. Fix the specific problem in the transcriber namespace; the clone in DIR/Transcripts and the snapshots in
     DIR/cache stay available as read-only reference for any single file you need to compare.'''


def cmd_rollback(ctx, args):
    dest, info, before, journal_path, journal = load_backup(ctx, args.backup)
    require_stopped(ctx)
    if journal['status'] == 'complete':
        after = load_json(dest / 'inventory-after.json')
        changed = diff_inventories(after, inventory(ctx.transcripts, label='live archive'))
        if not changed and frozen_state(ctx) != load_json(dest / 'after.json'):
            changed = ['index, worker state or archive-config.json']
        if changed:
            print(FIX_FORWARD.format(why=', '.join(changed[:3]) + (' ...' if len(changed) > 3 else '')))
            return 2
        say('ok', 'live data still equals the post-migration manifest; exact rollback allowed')
        journal['status'] = 'rolling-back'
        write(journal_path, encode(journal))
    elif journal['status'] == 'rolling-back':
        say('info', 'resuming rollback')
        clean_temp_files(ctx, before, dest)
    else:
        raise Surprise(f'journal status is {journal["status"]!r}; rollback needs a complete migration')

    clone = dest / 'Transcripts'
    if ctx.new_dir.is_dir() and not ctx.old_dir.exists():
        rename(ctx.new_dir, ctx.old_dir)
        say('did', 'renamed records/transcriber -> records/sotto')
    restored = 0
    for rel, e in sorted(before.items()):
        if e['t'] == 'f' and (rel.count('/') == 0 or re.fullmatch(r'records/sotto/[^/]+/metadata\.json', rel)):
            data = (clone / rel).read_bytes()
            if sha_bytes(data) != e['sha']:
                raise Surprise(f'clone copy of {rel} no longer matches the inventory')
            if (ctx.transcripts / rel).read_bytes() != data:
                write(ctx.transcripts / rel, data, e['mode'])
                restored += 1
    say('did', f'restored {restored} metadata/top-level files from the clone')

    db, snap = sqlite3.connect(ctx.index), sqlite3.connect((dest / 'cache' / 'index.sqlite').as_uri() + '?mode=ro', uri=True)
    try:
        snap.backup(db)
        db.execute('pragma wal_checkpoint(TRUNCATE)')
    finally:
        snap.close()
        db.close()
    state_bytes = (dest / 'cache' / ctx.old_state.name).read_bytes()
    if sha_bytes(state_bytes) != info['state_sha']:
        raise Surprise('state backup is damaged')
    write(ctx.old_state, state_bytes)
    if ctx.new_state.exists():
        unlink(ctx.new_state)
    config_bytes = (dest / 'repo-local' / ctx.config.name).read_bytes()
    if sha_bytes(config_bytes) != info['config_sha']:
        raise Surprise('config backup is damaged')
    write(ctx.config, config_bytes)
    say('did', 'index, sotto-state.json and archive-config.json restored from the snapshots')

    problems = diff_inventories(before, inventory(ctx.transcripts, label='rolled-back archive'), relax=())
    if problems:
        raise Surprise(f'rolled-back archive still differs from the backup: {problems[:5]}; rerun rollback')
    if (index_digest(ctx.index)[0] != info['index_digest'] or digest(ctx.old_state) != info['state_sha']
            or digest(ctx.config) != info['config_sha']):
        raise Surprise('index, state or config differs from the backup; rerun rollback')
    journal['status'] = 'rolled-back'
    journal['rolled_back_verified_at'] = now()
    write(journal_path, encode(journal))
    say('PASS', 'archive is byte-identical to the backup; run migrate-sotto-launchd.sh rollback --dir DIR')
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--transcripts', default=str(Path.home() / 'Transcripts'))
    p.add_argument('--repo', default=None, help='main checkout (default: from git)')
    p.add_argument('--cache', default=None, help='default: <repo>/.local/archive-cache')
    p.add_argument('--launch-agents', default=str(Path.home() / 'Library/LaunchAgents'))
    p.add_argument('--unsafe-skip-service-check', action='store_true', help='scratch rehearsals only; refused for real data')
    sub = p.add_subparsers(dest='command', required=True)
    sub.add_parser('plan')
    s = sub.add_parser('drain-status')
    s.add_argument('--namespace', choices=(OLD, NEW), required=True)
    s = sub.add_parser('backup')
    s.add_argument('--dest', required=True)
    for name in ('migrate', 'verify', 'rollback'):
        sub.add_parser(name).add_argument('--backup', required=True)
    args = p.parse_args()
    args.repo = args.repo or str(main_repo())
    os.umask(0o077)
    ctx = Ctx(args)
    try:
        return {'plan': cmd_plan, 'drain-status': cmd_drain_status, 'backup': cmd_backup, 'migrate': cmd_migrate,
                'verify': cmd_verify, 'rollback': cmd_rollback}[args.command](ctx, args)
    except Surprise as e:
        say('FAIL', str(e))
        return 2
    except Exception as e:  # the journal keeps finished steps; rerunning the same command resumes
        say('FAIL', f'{type(e).__name__}: {e}')
        return 3


if __name__ == '__main__':
    sys.exit(main())
