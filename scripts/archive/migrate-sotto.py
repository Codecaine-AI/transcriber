#!/usr/bin/env python3
"""One-off move of the transcript archive from the `sotto` source id to `transcriber`.

Subcommands, in order: plan (read-only), backup, migrate, verify. rollback is exact and refuses unless
every path, the index, the worker state and the config equal either the backup or its intended transform.
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
import secrets
import shutil
import sqlite3
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from archive import digest, encode, safe_id  # noqa: E402  (the worker's own byte encoding)

OLD, NEW = 'sotto', 'transcriber'
LABELS = ('server', 'archive', 'app')
PORTS = (8391, 8392)
STEPS = ('move', 'files', 'index', 'state', 'config')
IN_FLIGHT = ('receiving', 'queued', 'transcribing', 'proofreading')
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


TEMP_LOG = None  # DIR/temp-files.log: every temp path this tool creates, appended before it exists


def journal_temp(name):
    if TEMP_LOG is None:
        raise RuntimeError('no temp-file journal for this command')
    with open(TEMP_LOG, 'a') as f:
        f.write(f'{name}\n')
        f.flush()
        os.fsync(f.fileno())


def write(path, data, mode=0o600):
    """archive.atomic() plus an explicit mode and a parent-directory fsync. The temp file is created exclusively
    (an existing file of that name is never touched) and journaled only once it is ours."""
    path = Path(path)
    while True:
        name = str(path.parent / f'.{path.name}-{secrets.token_hex(4)}')
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            continue
    journal_temp(name)
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

def raise_error(error):
    raise error


def hash_file(path, sync=False):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
        if sync:
            os.fsync(f.fileno())
    return h.hexdigest()


def inventory(base, hashed=True, sync=False, label=None):
    """Typed entry for every path under base: d(mode), f(mode,size,sha), l(target).

    Unreadable directories and special files raise. With sync, every file and then every directory
    (deepest first) is fsynced, so a backup is durable before it is published."""
    started = time.monotonic()
    entries = {}
    for root, dirs, names in os.walk(base, onerror=raise_error):
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
            for rel, sha in zip(files, pool.map(lambda r: hash_file(os.path.join(base, r), sync), files)):
                entries[rel]['sha'] = sha
        total = sum(entries[r]['size'] for r in files)
        say('time', f'{label or base}: {len(entries)} entries, {len(files)} files, {total / 1e9:.2f} GB hashed'
                    f'{" and fsynced" if sync else ""} in {time.monotonic() - started:.1f}s')
    if sync:
        for rel in sorted((r for r, e in entries.items() if e['t'] == 'd'), key=lambda r: -r.count(os.sep)):
            fsync_dir(os.path.join(base, rel))
        fsync_dir(base)
        fsync_dir(os.path.dirname(os.path.abspath(base)))
    return entries


def save_inventory(path, entries):
    write(path, json.dumps(entries, sort_keys=True, separators=(',', ':')).encode())


def junk(rel):
    """Finder writes .DS_Store files at will; they are compared by type only and restored on rollback."""
    return os.path.basename(rel) == '.DS_Store'


def diff_inventories(a, b, unstable=()):
    """Paths whose entries differ. .DS_Store compares by type when present on both sides; paths in
    unstable compare by type and mode only."""
    out = []
    for rel in sorted(set(a) | set(b)):
        x, y = a.get(rel), b.get(rel)
        if junk(rel):
            if x and y and x['t'] != y['t']:
                out.append(f'type: {rel}')
        elif x is None or y is None:
            out.append(f'{"extra" if x is None else "missing"}: {rel}')
        elif rel in unstable:
            if (x['t'], x.get('mode')) != (y['t'], y.get('mode')):
                out.append(f'type/mode: {rel}')
        elif x != y:
            out.append(f'changed: {rel}')
    return out


def is_meta(rel):
    return re.fullmatch(r'records/sotto/[^/]+/metadata\.json', rel) is not None


OWN_NAMES = {'cache': (f'{OLD}-state.json', f'{NEW}-state.json', 'index.sqlite'), 'repo-local': ('archive-config.json',),
             'migration': ('journal.json', 'backup.json', 'inventory-before.json', 'temp-files.log')}


def same_hard_link(a, b):
    """True only when both paths are regular files (not symlinks) sharing one inode, so removing one keeps the bytes."""
    sa, sb = os.lstat(a), os.lstat(b)
    return (stat.S_ISREG(sa.st_mode) and stat.S_ISREG(sb.st_mode)
            and (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino) and sa.st_nlink >= 2)


def quarantine_temp_files(ctx, known, dest):
    """Move every leftover temp-looking file (ours from a crash or anyone else's) into DIR/quarantine/<where>/<path>.
    Nothing is deleted; an existing quarantine entry is never replaced. Returns the moved paths."""
    places = [('Transcripts', ctx.transcripts, None)]
    for d in (ctx.new_dir, ctx.old_dir):
        if d.is_dir():
            places += [('Transcripts', x, None) for x in d.iterdir() if x.is_dir()]
    places += [('cache', ctx.cache, OWN_NAMES['cache']), ('repo-local', ctx.local, OWN_NAMES['repo-local']),
               ('migration', dest, OWN_NAMES['migration'])]
    found = []
    for where, d, names in places:
        for p in d.iterdir():
            if not (p.is_file() and TEMP_FILE.match(p.name)):
                continue
            if names is not None and p.name[1:-9] not in names:
                continue  # outside the archive only our own write targets are considered
            rel = os.path.relpath(p, ctx.transcripts) if where == 'Transcripts' else p.name
            if where == 'Transcripts' and (rel in known or rel.replace(f'records/{NEW}/', f'records/{OLD}/', 1) in known):
                continue  # present at backup time: archive data
            found.append((p, dest / 'quarantine' / where / rel))
    moved = []
    for src, dst in found:
        dst.parent.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(dst) and same_hard_link(src, dst):
            pass  # an interrupted earlier run linked it but did not unlink the source: finish that move
        else:
            base, n = dst, 0
            while True:
                try:
                    os.link(src, dst)  # exclusive: nothing in quarantine is ever replaced
                    break
                except FileExistsError:
                    n += 1
                    dst = base.with_name(f'{base.name}.{n}')
            fsync_dir(dst.parent)
        unlink(src)
        with open(dest / 'quarantine.log', 'a') as f:
            f.write(f'{now()} {src} -> {dst}\n')
            f.flush()
            os.fsync(f.fileno())
        say('did', f'quarantined leftover temp file {src} -> {dst}')
        moved.append((src, dst))
    if moved:
        say('info', f'{len(moved)} leftover temp file(s) moved to {dest / "quarantine"}; review them, nothing was deleted')
    return moved


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


def show_diff(name, before, after):
    for line in difflib.unified_diff(before.decode().splitlines(), after.decode().splitlines(),
                                     f'a/{name}', f'b/{name}', lineterm='', n=1):
        print('    ' + line)


# ---------------------------------------------------------------- index, services, drain

ROW = 'key,source,timestamp,status,app,raw,clean,path,audio,screenshot,bytes'


def ro(path):
    return sqlite3.connect(Path(path).as_uri() + '?mode=ro', uri=True)


def index_counts(db):
    return dict(db.execute('select source, count(*) from records group by source').fetchall())


def index_rows(path):
    db = ro(path)
    try:
        return db.execute(f'select {ROW} from records').fetchall()
    finally:
        db.close()


def renamed_rows(rows):
    """The index rows exactly as migrate's UPDATE leaves them."""
    out = []
    for row in rows:
        if row[1] == OLD:
            row = (NEW + '/' + row[0][len(OLD) + 1:], NEW) + row[2:7] + \
                  (f'records/{NEW}/' + row[7][len(f'records/{OLD}/'):],) + row[8:]
        out.append(row)
    return out


def rows_digest(rows):
    h = hashlib.sha256()
    for row in sorted(rows, key=lambda r: r[0]):
        h.update(json.dumps(row, ensure_ascii=False).encode() + b'\n')
    return h.hexdigest()


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


KNOWN_STATUS = IN_FLIGHT + ('completed', 'failed', 'cancelled')


def drain(ctx, namespace):
    """Server takes not yet terminal, and finished takes the archive worker has not copied yet. Strict: any listing
    or read error, a take folder without readable metadata, or an unknown status counts as unreadable, so callers
    fail closed."""
    receiving, in_flight, unarchived, unreadable = [], [], [], []
    try:
        with os.scandir(ctx.generations) as it:
            takes = sorted(it, key=lambda e: e.name)
    except OSError as e:
        return {'receiving': 0, 'in_flight': 0, 'unarchived': 0, 'unreadable': 1, 'examples': [str(e)]}
    state_path = ctx.cache / f'{namespace}-state.json'
    state = load_json(state_path) if state_path.exists() else {}
    for take in takes:
        if take.name == '.DS_Store':
            continue
        path = Path(take.path) / 'metadata.json'
        try:
            if not take.is_dir(follow_symlinks=False):
                raise OSError(f'not a take folder: {take.name}')
            with os.scandir(take.path) as it:
                names = {x.name for x in it}
            if 'metadata.json' not in names:
                raise OSError(f'{take.name} has no metadata.json')
            m = load_json(path)
            st = path.stat()
            if m.get('status') not in KNOWN_STATUS:
                raise ValueError(f'{take.name} has unknown status {m.get("status")!r}')
        except (OSError, ValueError) as e:
            unreadable.append(str(e) or take.name)
            continue
        if m['status'] == 'receiving':
            receiving.append(take.name)
        if m['status'] in IN_FLIGHT:
            in_flight.append(take.name)
        elif not m.get('importedSource') and (
                state.get(str(path)) != [st.st_mtime_ns, st.st_size]
                or not (ctx.records / namespace / safe_id(take.name) / 'metadata.json').exists()):
            unarchived.append(take.name)
    return {'receiving': len(receiving), 'in_flight': len(in_flight), 'unarchived': len(unarchived),
            'unreadable': len(unreadable), 'examples': (unreadable + receiving + in_flight + unarchived)[:5]}


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
        if p.name == '.DS_Store':
            continue
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


RUN_ORDER = 'plan -> down -> plan --dir -> backup -> migrate -> verify -> merge into main -> up'


def cmd_plan(ctx, args):
    say('info', f'transcripts={ctx.transcripts} cache={ctx.cache} repo={ctx.repo}')
    say('info', f'run order: {RUN_ORDER}')
    plists = ctx.agents
    if args.dir and not list(ctx.agents.glob(f'ai.codecaine.{OLD}.*.plist')):
        plists = Path(args.dir).expanduser().resolve() / 'launchd' / 'LaunchAgents'
        say('info', f'sotto plists are stashed by down; checking {plists}')
    elif not list(ctx.agents.glob(f'ai.codecaine.{OLD}.*.plist')):
        say('info', 'no sotto plists in LaunchAgents: after down, pass --dir DIR to check the stashed copies')
    _, s = inspect(ctx, plists)
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


# ---------------------------------------------------------------- the intended change, and the one comparator

def new_config(ctx):
    cfg = load_json(ctx.config)
    return encode({'archive_root': str(ctx.transcripts), 'transcriber_data': str(ctx.local / 'server'),
                   'viewer_url': cfg.get('viewer_url', 'http://127.0.0.1:8392')})


def clone_bytes(clone, before, rel):
    """Bytes of a clone file, only if they still match the backup inventory."""
    data = (clone / rel).read_bytes()
    if sha_bytes(data) != before[rel]['sha']:
        raise Surprise(f'the backup clone copy of {rel} no longer matches inventory-before.json')
    return data


def new_bytes(clone, before, rel):
    """The transformed bytes of a file migrate rewrites, built from the authenticated backup clone."""
    data = json.loads(clone_bytes(clone, before, rel))
    if rel == 'dataset.json':
        if data.get('sources') != ['wispr-flow', OLD]:
            raise Surprise(f'dataset.json sources {data.get("sources")}')
        return encode(dict(data, sources=['wispr-flow', NEW]))
    return encode(transform(data, OLD, NEW))


def rewritten(rel):
    return rel == 'dataset.json' or is_meta(rel)


def check_all(ctx, dest, info, before, allowed, label='live archive'):
    """Compare everything migrate may touch against the backup. Every path, the index, the worker state and the
    config must each be in an allowed form: 'old' (the backup) or 'new' (the backup transformed exactly as migrate
    does). Any other difference, extra or missing path is a problem. Returns (problems, forms seen)."""
    problems, seen = [], set()
    clone = dest / 'Transcripts'
    old_named, new_named = ctx.old_dir.exists(), ctx.new_dir.exists()
    if old_named == new_named:
        return [f'expected exactly one of records/{OLD} and records/{NEW}'], seen
    seen.add('new' if new_named else 'old')
    live = inventory(ctx.transcripts, label=label)
    mapped = {(re.sub(rf'^records/{NEW}(?=/|$)', f'records/{OLD}', r) if new_named else r): e for r, e in live.items()}
    def shown(rel):  # report paths under their live name
        return re.sub(rf'^records/{OLD}(?=/|$)', f'records/{NEW}', rel) if new_named else rel

    for rel in sorted(set(before) | set(mapped)):
        x, y = before.get(rel), mapped.get(rel)
        if junk(rel):
            if x and y and x['t'] != y['t']:
                problems.append(f'type: {shown(rel)}')
        elif x is None or y is None:
            problems.append(f'{"extra" if x is None else "missing"}: {shown(rel)}')
        elif rel == UNSTABLE:
            if (x['t'], x['mode']) != (y['t'], y['mode']):
                problems.append(f'type/mode: {rel}')
        elif rewritten(rel) and x['t'] == y['t'] == 'f' and x['mode'] == y['mode']:
            if y['sha'] == x['sha']:
                seen.add('old')
            elif y['sha'] == sha_bytes(new_bytes(clone, before, rel)):
                seen.add('new')
            else:
                problems.append(f'changed beyond the intended fields: {shown(rel)}')
        elif x != y:
            problems.append(f'changed: {shown(rel)}')

    digest_now = rows_digest(index_rows(ctx.index))
    forms = {info['index_old']: 'old', info['index_new']: 'new'}
    if digest_now in forms:
        seen.add(forms[digest_now])
    else:
        problems.append('index rows differ from both the backup snapshot and its intended transform')
    states = []
    if ctx.old_state.exists():
        states.append('old' if digest(ctx.old_state) == info['state_sha'] else 'other')
    if ctx.new_state.exists():
        states.append('new' if digest(ctx.new_state) == info['state_new_sha'] else 'other')
    if not states or 'other' in states:
        problems.append('worker state differs from both its backup and its intended form')
    seen.update(s for s in states if s != 'other')
    config_form = {info['config_sha']: 'old', info['config_new_sha']: 'new'}.get(digest(ctx.config))
    if config_form:
        seen.add(config_form)
    else:
        problems.append('archive-config.json differs from both its backup and its intended form')
    if seen - set(allowed):
        problems.append(f'found {sorted(seen)} forms where only {sorted(allowed)} is allowed')
    return problems, seen


def authenticate(ctx, dest, info, before):
    """Before anything changes: every backup input migrate, verify or rollback will read must match its record."""
    started = time.monotonic()
    clone = dest / 'Transcripts'
    rels = [r for r, e in before.items() if e['t'] == 'f' and (rewritten(r) or r == UNSTABLE or junk(r))]
    bad = [r for r in rels if not (clone / r).is_file() or hash_file(clone / r) != before[r]['sha']]
    snapshot = dest / 'cache' / 'index.sqlite'
    db = ro(snapshot)
    try:
        integrity = db.execute('pragma integrity_check').fetchone()[0]
    finally:
        db.close()
    if integrity != 'ok' or rows_digest(index_rows(snapshot)) != info['index_old']:
        bad.append('cache/index.sqlite snapshot')
    for path, sha in ((dest / 'cache' / ctx.old_state.name, info['state_sha']),
                      (dest / 'repo-local' / ctx.config.name, info['config_sha'])):
        if not path.is_file() or hash_file(path) != sha:
            bad.append(str(path.relative_to(dest)))
    if bad:
        raise Surprise(f'the backup in {dest} is damaged; nothing was changed. Damaged: {bad[:5]}')
    say('ok', f'backup inputs authenticated: {len(rels)} clone files, index snapshot (integrity ok, rows match), '
              f'state and config copies ({time.monotonic() - started:.1f}s)')


def fail_if(problems, what):
    if problems:
        raise Surprise(f'{what}: {len(problems)} difference(s): {problems[:5]}')


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
        raise Surprise(f'{len(s)} precondition(s) failed; run plan --dir DEST')
    dest.mkdir(parents=True, exist_ok=True)
    global TEMP_LOG
    TEMP_LOG = dest / 'temp-files.log'
    if dest.stat().st_dev != ctx.transcripts.stat().st_dev:
        raise Surprise('the backup must be on the archive volume so cp -c can clone')

    started = time.monotonic()
    clone = dest / 'Transcripts'
    if clone.exists():
        raise Surprise(f'{clone} exists from an unfinished backup; move it aside and rerun')
    subprocess.run(['cp', '-c', '-p', '-R', str(ctx.transcripts), str(clone)], check=True)
    say('time', f'APFS clone in {time.monotonic() - started:.1f}s')
    before = inventory(clone, sync=True, label='clone')
    fail_if(diff_inventories(before, inventory(ctx.transcripts, label='live archive')), 'clone vs live archive')
    say('ok', f'clone equals the live archive: {len(before)} entries, every file hashed on both sides')

    (dest / 'cache').mkdir()
    (dest / 'repo-local').mkdir()
    snapshot = dest / 'cache' / 'index.sqlite'
    src, dst = ro(ctx.index), sqlite3.connect(snapshot)
    try:
        src.backup(dst)
    finally:
        src.close()
        dst.close()
    rows = index_rows(snapshot)
    if rows_digest(rows) != rows_digest(index_rows(ctx.index)):
        raise Surprise('index snapshot differs from the live index')
    for src_path, dst_path in ((ctx.old_state, dest / 'cache' / ctx.old_state.name),
                               (ctx.config, dest / 'repo-local' / ctx.config.name)):
        shutil.copy2(src_path, dst_path)
    keep = {k: v for k, v in load_json(ctx.old_state).items() if k.startswith(ctx.state_prefix)}
    info = {'status': 'complete', 'created_at': now(), 'transcripts': str(ctx.transcripts), 'cache': str(ctx.cache),
            'repo': str(ctx.repo), 'launch_agents': str(ctx.agents), 'records': f['records'], 'wispr': f['wispr'],
            'index_old': rows_digest(rows), 'index_new': rows_digest(renamed_rows(rows)),
            'state_sha': hash_file(ctx.old_state), 'state_new_sha': sha_bytes(encode(keep)),
            'config_sha': hash_file(ctx.config), 'config_new_sha': sha_bytes(new_config(ctx)),
            'launchd': {p.name: hash_file(p) for p in sorted(plists.iterdir())}}
    if (hash_file(dest / 'cache' / ctx.old_state.name) != info['state_sha']
            or hash_file(dest / 'repo-local' / ctx.config.name) != info['config_sha']):
        raise Surprise('state or config copy differs')
    save_inventory(dest / 'inventory-before.json', before)
    for d in ('cache', 'repo-local'):  # durable before publishing backup.json
        inventory(dest / d, sync=True, label=f'backup {d}/')
    inventory(dest / 'launchd', sync=True, label='backup launchd/')
    write(dest / 'backup.json', encode(info))
    say('PASS', f'backup complete and fsynced in {time.monotonic() - started:.0f}s: {dest}')
    return 0


def load_backup(ctx, path):
    dest = Path(path).expanduser().resolve()
    if not (dest / 'backup.json').is_file():
        raise Surprise(f'no completed backup in {dest}')
    info = load_json(dest / 'backup.json')
    if info.get('status') != 'complete':
        raise Surprise('backup is incomplete')
    for key, value in (('transcripts', ctx.transcripts), ('cache', ctx.cache), ('repo', ctx.repo)):
        if info[key] != str(value):
            raise Surprise(f'backup was taken for {key}={info[key]}, not {value}')
    global TEMP_LOG
    TEMP_LOG = dest / 'temp-files.log'
    journal_path = dest / 'journal.json'
    journal = load_json(journal_path) if journal_path.exists() else {'status': 'new', 'steps': {}}
    return dest, info, load_json(dest / 'inventory-before.json'), journal_path, journal


# ---------------------------------------------------------------- migrate

def cmd_migrate(ctx, args):
    dest, info, before, journal_path, journal = load_backup(ctx, args.backup)
    if journal['status'] not in ('new', 'running'):
        raise Surprise(f'migration is {journal["status"]} for this backup; refusing to run again')
    require_stopped(ctx)
    authenticate(ctx, dest, info, before)
    if journal['status'] == 'running':
        say('info', f'resuming; finished: {[k for k, v in journal["steps"].items() if "finished_at" in v]}')
        quarantine_temp_files(ctx, before, dest)
        fail_if(check_all(ctx, dest, info, before, {'old', 'new'})[0], 'archive is neither the backup nor its transform')
    else:
        fail_if(check_all(ctx, dest, info, before, {'old'})[0], 'archive changed since the backup')
    journal['status'] = 'running'
    n = info['records']
    clone = dest / 'Transcripts'

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
        return 'already in place (resumed)'

    def files():
        written = resumed = 0
        for rel, e in sorted(before.items()):
            if not rewritten(rel):
                continue
            live = ctx.transcripts / re.sub(rf'^records/{OLD}/', f'records/{NEW}/', rel)
            target = new_bytes(clone, before, rel)
            sha = hash_file(live)
            if sha == e['sha']:
                write(live, target, e['mode'])
                written += 1
            elif sha == sha_bytes(target):
                resumed += 1
            else:
                raise Surprise(f'{rel} changed since the backup')
        if written + resumed != n + 1:
            raise Surprise(f'{written + resumed} files, expected {n} metadata + dataset.json')
        return {'rewritten': written, 'already_done': resumed}

    def index():
        db = sqlite3.connect(ctx.index, isolation_level=None)
        try:
            db.execute('begin immediate')
            current = rows_digest(db.execute(f'select {ROW} from records').fetchall())
            if current == info['index_new']:
                db.execute('rollback')
                return 'already migrated (resumed; rows equal the transformed backup)'
            if current != info['index_old']:
                raise Surprise('index rows differ from the backup snapshot')
            cur = db.execute("update records set key='transcriber/'||substr(key,7), source='transcriber', "
                             "path='records/transcriber/'||substr(path,15) where source='sotto'")
            after = rows_digest(db.execute(f'select {ROW} from records').fetchall())
            if cur.rowcount != n or after != info['index_new']:
                raise Surprise('updated rows differ from the transformed backup rows')
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

    def state():
        if ctx.old_state.exists():
            if hash_file(ctx.old_state) != info['state_sha']:
                raise Surprise('sotto-state.json changed since the backup')
            keep = {k: v for k, v in load_json(ctx.old_state).items() if k.startswith(ctx.state_prefix)}
            if len(keep) != n or sha_bytes(encode(keep)) != info['state_new_sha']:
                raise Surprise(f'{len(keep)} current-repo state keys, expected {n}')
            write(ctx.new_state, encode(keep))
            unlink(ctx.old_state)  # its exact bytes are in the backup
        return {'kept_keys': n}

    def config():
        if hash_file(ctx.config) == info['config_sha']:
            data = new_config(ctx)
            show_diff('archive-config.json', ctx.config.read_bytes(), data)
            write(ctx.config, data)
        return 'archive-config.json uses transcriber_data'

    for name, fn in zip(STEPS, (move, files, index, state, config)):
        step(name, fn)
    fail_if(check_all(ctx, dest, info, before, {'new'}, 'migrated archive')[0], 'migrated archive is not the intended form')
    journal['status'] = 'complete'
    journal['finished_at'] = now()
    write(journal_path, encode(journal))
    say('PASS', 'migration complete and checked against the transformed backup; run verify next')
    return 0


# ---------------------------------------------------------------- verify

def cmd_verify(ctx, args):
    dest, info, before, journal_path, journal = load_backup(ctx, args.backup)
    if journal['status'] != 'complete':
        raise Surprise(f'journal status is {journal["status"]!r}, expected complete')
    authenticate(ctx, dest, info, before)
    quarantine_temp_files(ctx, before, dest)  # compare the tree without leftover temp files
    fail_if(check_all(ctx, dest, info, before, {'new'})[0], 'archive is not the transformed backup')
    say('ok', f'every path equals the backup apart from records/sotto -> records/transcriber, {info["records"]} '
              'metadata files and dataset.json (exactly the intended fields); index rows, worker state and config '
              'equal the transformed backup')
    db = ro(ctx.index)
    try:
        if db.execute('pragma quick_check').fetchone()[0] != 'ok':
            raise Surprise('index quick_check failed')
    finally:
        db.close()
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


# ---------------------------------------------------------------- rollback (exact; only while data is unchanged)

def cmd_rollback(ctx, args):
    dest, info, before, journal_path, journal = load_backup(ctx, args.backup)
    require_stopped(ctx)
    status = journal['status']
    if status == 'new':
        raise Surprise('no migration step has run, so there is no data to roll back; restore the services with '
                       'migrate-sotto-launchd.sh rollback --dir DIR')
    if status == 'rolled-back':
        raise Surprise('already rolled back')
    authenticate(ctx, dest, info, before)  # every input rollback restores, before it changes anything
    quarantine_temp_files(ctx, before, dest)  # compare the tree without leftover temp files
    problems, _ = check_all(ctx, dest, info, before, {'old', 'new'})
    if problems:
        print(f'Rollback is refused: {len(problems)} path(s) differ from both the backup and its intended transform:')
        for p in problems[:10]:
            print('    ' + p)
        if journal.get('verified_at'):
            print('The transcriber services ran after verify, so this is newer data. Fix forward instead:\n'
                  '    bash scripts/archive/migrate-sotto-launchd.sh start --dir DIR   (keep the new code)')
        else:
            print('Verify never passed, so no service has run since migrate; the services are still stopped.\n'
                  'Something outside the migration changed these paths. Inspect them against DIR/Transcripts,\n'
                  'restore or remove them by hand, then rerun: migrate-sotto.py rollback --backup DIR')
        return 2
    if status != 'rolling-back':
        journal['status'] = 'rolling-back'
        write(journal_path, encode(journal))
    clone = dest / 'Transcripts'

    if ctx.new_dir.is_dir() and not ctx.old_dir.exists():
        rename(ctx.new_dir, ctx.old_dir)
        say('did', 'renamed records/transcriber -> records/sotto')
    restored = 0
    for rel, e in sorted(before.items()):  # only the files migrate or verify rewrite, plus Finder's .DS_Store
        if e['t'] == 'f' and (rewritten(rel) or rel == UNSTABLE or junk(rel)):
            p = ctx.transcripts / rel
            if not p.is_file() or hash_file(p) != e['sha']:
                write(p, clone_bytes(clone, before, rel), e['mode'])
                restored += 1
    for rel, e in inventory(ctx.transcripts, hashed=False).items():
        if junk(rel) and rel not in before:
            unlink(ctx.transcripts / rel)
            restored += 1
    say('did', f'restored {restored} metadata, dataset, verification and .DS_Store files from the clone')

    db = sqlite3.connect(ctx.index)
    snap = sqlite3.connect((dest / 'cache' / 'index.sqlite').as_uri() + '?mode=ro', uri=True)
    try:
        snap.backup(db)
        db.execute('pragma wal_checkpoint(TRUNCATE)')
    finally:
        snap.close()
        db.close()
    for src, target, sha in ((dest / 'cache' / ctx.old_state.name, ctx.old_state, info['state_sha']),
                             (dest / 'repo-local' / ctx.config.name, ctx.config, info['config_sha'])):
        data = src.read_bytes()
        if sha_bytes(data) != sha:
            raise Surprise(f'{src} is damaged')
        if not target.exists() or hash_file(target) != sha:
            write(target, data)
    if ctx.new_state.exists():
        unlink(ctx.new_state)
    say('did', 'index, sotto-state.json and archive-config.json restored from the snapshots')

    problems, _ = check_all(ctx, dest, info, before, {'old'}, 'rolled-back archive')
    live = inventory(ctx.transcripts, hashed=False)
    if UNSTABLE in before and hash_file(ctx.transcripts / UNSTABLE) != before[UNSTABLE]['sha']:
        problems.append(f'{UNSTABLE} differs')
    problems += [f'.DS_Store differs: {r}' for r in live if junk(r) and r not in before]
    fail_if(problems, 'rolled-back archive differs from the backup; rerun rollback')
    journal['status'] = 'rolled-back'
    journal['rolled_back_verified_at'] = now()
    write(journal_path, encode(journal))
    say('PASS', 'archive equals the backup; run migrate-sotto-launchd.sh rollback --dir DIR')
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--transcripts', default=str(Path.home() / 'Transcripts'))
    p.add_argument('--repo', default=None, help='main checkout (default: from git)')
    p.add_argument('--cache', default=None, help='default: <repo>/.local/archive-cache')
    p.add_argument('--launch-agents', default=str(Path.home() / 'Library/LaunchAgents'))
    p.add_argument('--unsafe-skip-service-check', action='store_true', help='scratch rehearsals only; refused for real data')
    sub = p.add_subparsers(dest='command', required=True)
    sub.add_parser('plan').add_argument('--dir', help='migration directory, once down has stashed the plists')
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
