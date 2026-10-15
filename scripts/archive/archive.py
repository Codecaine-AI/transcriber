#!/usr/bin/env python3
"""Portable transcript archive. Original files are authoritative; SQLite is a local search cache."""
from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import json
import os
import re
import shutil
import sqlite3
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

CHUNK = 1024 * 1024
TEXT_COLUMNS = ('asrText', 'formattedText', 'editedText', 'pastedText', 'serverFinalizedText',
                'defaultAsrText', 'fallbackAsrText', 'defaultFormattedText', 'fallbackFormattedText',
                'editedTextUnbounded', 'toneMatchedText', 'desiredAsr', 'desiredFormatted')
MEDIA = {'audio': ('audio', '.wav'), 'screenshot': ('screenshot', '.png'),
         'opusChunks': ('opus', '.json'), 'builtInAudio': ('original-audio', '.bin')}


def now():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(CHUNK), b''):
            h.update(chunk)
    return h.hexdigest()


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def safe_id(value):
    if isinstance(value, str) and re.fullmatch(r'source-[0-9a-f]{64}', value):
        return value
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        return 'source-' + hashlib.sha256(str(value).encode()).hexdigest()


def date(value):
    if not value:
        return None
    text = str(value).replace(' Z', '+00:00').replace(' +', '+').replace(' -', '-')
    try:
        d = datetime.fromisoformat(text.replace('Z', '+00:00'))
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')
    except ValueError:
        return None


def typed(value):
    if value is None:
        return {'type': 'null'}
    if isinstance(value, bytes):
        return {'type': 'blob', 'base64': base64.b64encode(value).decode()}
    if isinstance(value, float) and not (-float('inf') < value < float('inf')):
        return {'type': 'real', 'value': repr(value)}
    return {'type': 'integer' if isinstance(value, int) else 'real' if isinstance(value, float) else 'text', 'value': value}


class Archive:
    def __init__(self, root, cache):
        self.root = Path(root).expanduser().resolve()
        self.cache = Path(cache).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.cache / 'index.sqlite', check_same_thread=False)
        self.db.execute('pragma journal_mode=wal')
        self.db.execute('''create table if not exists records (
            key text primary key, source text, timestamp text, status text, app text,
            raw text, clean text, path text, audio integer, screenshot integer, bytes integer)''')
        self.db.execute('create index if not exists records_date on records(timestamp desc)')
        self.db.execute('create index if not exists records_source on records(source)')
        self.db.commit()
        self.state_path = self.cache / 'transcriber-state.json'
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        self.last_error = None
        self.last_sync = None
        marker = self.root / 'dataset.json'
        if marker.exists():
            marker_data = json.loads(marker.read_text())
            if marker_data.get('format') != 'codecaine-transcripts':
                raise ValueError('The destination contains a different dataset format')
        else:
            atomic(marker, encode({'format': 'codecaine-transcripts', 'schema_version': 1,
                'id': str(uuid.uuid4()), 'name': 'Transcripts', 'created_at': now(),
                'records': 'records/<source>/<record-id>/metadata.json',
                'text_files': {'raw': 'raw.txt', 'clean': 'clean.txt'},
                'sources': ['wispr-flow', 'transcriber'], 'artifact_size_limit': None,
                'retention': 'Archive records survive deletion from the source application.'}))

    def record_dir(self, source, identifier):
        if source not in ('wispr-flow', 'transcriber'):
            raise ValueError('Unknown source')
        return self.root / 'records' / source / safe_id(identifier)

    def load(self, source, identifier):
        p = self.record_dir(source, identifier) / 'metadata.json'
        return json.loads(p.read_text()) if p.exists() else {
            'schema_version': 1, 'id': safe_id(identifier), 'source': source,
            'source_id': identifier, 'timestamp': None, 'status': None, 'text': {},
            'context': {}, 'artifacts': [], 'source_versions': [], 'archived_at': now()}

    def blob(self, record_dir, stream, kind, suffix, original_name):
        """Stream and verify every byte; no artifact size ceiling or whole-file allocation."""
        folder = record_dir / 'artifacts'
        folder.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(prefix='.incoming-', dir=folder)
        h = hashlib.sha256()
        size = 0
        try:
            with os.fdopen(fd, 'wb') as out:
                while chunk := stream.read(CHUNK):
                    out.write(chunk)
                    h.update(chunk)
                    size += len(chunk)
                out.flush()
                os.fsync(out.fileno())
            sha = h.hexdigest()
            destination = folder / (sha + suffix)
            if destination.exists():
                if destination.stat().st_size != size or digest(destination) != sha:
                    raise ValueError('An existing archive artifact is damaged')
            else:
                os.replace(temp, destination)
            return {'path': destination.relative_to(record_dir).as_posix(), 'kind': kind,
                    'original_name': original_name, 'bytes': size, 'sha256': sha}
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def version(self, record_dir, metadata, value, role, filename):
        data = encode(value)
        sha = hashlib.sha256(data).hexdigest()
        rel = 'source_versions/' + sha + '.json'
        p = record_dir / rel
        if not p.exists():
            atomic(p, data)
        elif digest(p) != sha:
            raise ValueError('An existing source version is damaged')
        entry = {'path': rel, 'sha256': sha, 'role': role, 'source_file': filename}
        if entry not in metadata['source_versions']:
            metadata['source_versions'].append(entry)

    @staticmethod
    def add_artifact(metadata, artifact):
        for existing in metadata['artifacts']:
            if existing['path'] == artifact['path'] and existing['kind'] == artifact['kind']:
                names = set(existing.get('original_names', [existing['original_name']]))
                names.update(artifact.get('original_names', [artifact['original_name']]))
                existing['original_names'] = sorted(names)
                return
        metadata['artifacts'].append(artifact)

    def save(self, metadata):
        folder = self.record_dir(metadata['source'], metadata['id'])
        metadata['files'] = {'raw': 'raw.txt', 'clean': 'clean.txt', 'metadata': 'metadata.json'}
        # Null is distinct from empty text in metadata; both have a portable empty text file.
        atomic(folder / 'raw.txt', (metadata['text'].get('raw') or '').encode())
        atomic(folder / 'clean.txt', (metadata['text'].get('clean') or '').encode())
        metadata['updated_at'] = now()
        atomic(folder / 'metadata.json', encode(metadata))
        self.index(metadata, folder)

    def index(self, m, folder):
        with self.lock:
            self.db.execute('insert or replace into records values (?,?,?,?,?,?,?,?,?,?,?)', (
                m['source'] + '/' + m['id'], m['source'], m.get('timestamp'), m.get('status'),
                str(m.get('context', {}).get('app') or ''), m.get('text', {}).get('raw') or '',
                m.get('text', {}).get('clean') or '', str(folder.relative_to(self.root)),
                int(any(a['kind'] in ('audio', 'original-audio') for a in m['artifacts'])),
                int(any(a['kind'] == 'screenshot' for a in m['artifacts'])),
                sum(a['bytes'] for a in m['artifacts'])))

    def commit(self):
        with self.lock:
            self.db.commit()

    def reindex(self):
        with self.lock:
            self.db.execute('delete from records')
            for path in sorted((self.root / 'records').glob('*/*/metadata.json')):
                self.index(json.loads(path.read_text()), path.parent)
            self.db.commit()

    def import_wisprsync(self, source):
        source = Path(source).expanduser().resolve()
        if source == self.root or source in self.root.parents or self.root in source.parents:
            raise ValueError('Export source and archive destination must be separate directories')
        marker = source / 'manifest.json'
        if not marker.is_file():
            raise ValueError('Choose a WisprSync export with manifest.json')
        # Retain export-level evidence exactly, including prior runs and indexes.
        evidence = self.root / 'sources' / 'wisprsync-export' / digest(marker)
        for part in ['manifest.json', 'indexes', 'runs']:
            base = source / part
            paths = [base] if base.is_file() else sorted(base.rglob('*')) if base.is_dir() else []
            for p in paths:
                if p.is_file():
                    if p.is_symlink():
                        raise ValueError('Source evidence cannot be a symbolic link')
                    dst = evidence / p.relative_to(source)
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    if not dst.exists():
                        shutil.copyfile(p, dst)
                    if digest(p) != digest(dst):
                        raise ValueError('Export evidence verification failed')
        count = 0
        for path in sorted((source / 'records').glob('*/*/*/*/metadata.json')):
            original = json.loads(path.read_text())
            m = self.load('wispr-flow', original['id'])
            folder = self.record_dir('wispr-flow', original['id'])
            self.version(folder, m, original, 'wisprsync-export', str(path.relative_to(source)))
            texts = original.get('text', {})
            # Live source is higher priority if a previous run already observed it.
            if m.get('selected_source') != 'wispr-flow-current':
                clean_key = next((k for k in ('pasted', 'formatted', 'asr') if texts.get(k)), 'formatted')
                m.update(timestamp=original.get('timestamps', {}).get('timestamp_utc'),
                         status=original.get('status', {}).get('wispr_status'),
                         text={'raw': texts.get('asr'), 'clean': texts.get(clean_key),
                               'clean_variant': clean_key, 'variants': texts},
                         context=original.get('context', {}),
                         duration_seconds=original.get('text_stats', {}).get('duration_seconds'),
                         selected_source='wisprsync-export')
            for key, name in original.get('files', {}).items():
                if not name or key == 'metadata':
                    continue
                p = (path.parent / name).resolve()
                if not p.is_relative_to(path.parent.resolve()) or not p.is_file():
                    raise ValueError('Missing or invalid file in WisprSync export')
                kind = 'audio' if key == 'audio' else 'screenshot' if key == 'screenshot' else 'source-text'
                with p.open('rb') as f:
                    artifact = self.blob(folder, f, kind, p.suffix, name)
                expected = original.get('media', {}).get(key, {}).get('sha256')
                if expected and artifact['sha256'] != expected:
                    raise ValueError('WisprSync media differs from its original integrity metadata')
                self.add_artifact(m, artifact)
            self.save(m)
            count += 1
            if count % 1000 == 0:
                self.commit()
                print(f'WisprSync: {count} records archived', flush=True)
        self.commit()
        return count

    def import_sqlite(self, source, role='current'):
        """Consistent read-only SQLite snapshot; preserve every History column and Dictionary row."""
        source = Path(source).expanduser().resolve()
        with tempfile.TemporaryDirectory(prefix='wispr-snapshot-', dir=self.cache) as tmp:
            snapshot = Path(tmp) / 'source.sqlite'
            reader = sqlite3.connect(source.as_uri() + '?mode=ro', uri=True, timeout=30)
            db = sqlite3.connect(snapshot)
            try:
                reader.backup(db)
            finally:
                reader.close()
            try:
                db.row_factory = sqlite3.Row
                columns = [r[1] for r in db.execute('pragma table_info(History)')]
                if 'transcriptEntityId' not in columns:
                    raise ValueError('History table is missing its source ID')
                names = ','.join('"' + c.replace('"', '""') + '"' for c in columns if c not in MEDIA)
                count = 0
                for row in db.execute('select rowid as __rowid,' + names + ' from History'):
                    values = dict(row)
                    rowid = values.pop('__rowid')
                    identifier = values.get('transcriptEntityId')
                    if identifier is None or identifier == '':
                        identifier = 'missing-id:' + source.name + ':' + str(rowid)
                    m = self.load('wispr-flow', identifier)
                    folder = self.record_dir('wispr-flow', identifier)
                    fields = {key: typed(v) for key, v in values.items()}
                    for col, (kind, suffix) in MEDIA.items():
                        if col not in columns:
                            continue
                        t, size = db.execute(f'select typeof("{col}"), length(cast("{col}" as blob)) from History where rowid=?', (rowid,)).fetchone()
                        if t in ('blob', 'text'):
                            # sqlite3_blob_open streams both TEXT and BLOB without decoding bytes.
                            with db.blobopen('History', col, rowid, readonly=True) as stream:
                                a = self.blob(folder, stream, kind, suffix, col)
                            if a['bytes'] != size:
                                raise ValueError('Source blob length changed during snapshot export')
                            self.add_artifact(m, a)
                            fields[col] = {'type': t, 'artifact': a['path'], 'sha256': a['sha256'], 'bytes': a['bytes']}
                        else:
                            fields[col] = typed(db.execute(f'select "{col}" from History where rowid=?', (rowid,)).fetchone()[0])
                    self.version(folder, m, {'table': 'History', 'rowid': rowid, 'values': fields},
                                 'wispr-flow-' + role, source.name)
                    if role == 'current' or not m.get('selected_source'):
                        variants = {k: values.get(k) for k in TEXT_COLUMNS if k in columns}
                        ck = next((k for k in ('pastedText', 'serverFinalizedText', 'formattedText', 'asrText') if values.get(k)), 'formattedText')
                        # Unknown timestamps stay unknown; no source rows are rejected.
                        m.update(timestamp=date(values.get('timestamp')), status=values.get('status'),
                            text={'raw': values.get('asrText'), 'clean': values.get(ck), 'clean_variant': ck, 'variants': variants},
                            context={k: values.get(k) for k in ('app','url','language','detectedLanguage','micDevice','platform','appVersion','conversationId')},
                            duration_seconds=values.get('duration'), selected_source='wispr-flow-' + role)
                    self.save(m)
                    count += 1
                    if count % 1000 == 0:
                        self.commit()
                        print(f'Wispr {role}: {count} records archived', flush=True)
                self.commit()
                if db.execute("select 1 from sqlite_master where name='Dictionary' and type='table'").fetchone():
                    entries = [{k: typed(v) for k, v in dict(row).items()} for row in db.execute('select * from Dictionary')]
                    data = encode({'schema_version': 1, 'source': source.name, 'role': role, 'rows': entries})
                    sha = hashlib.sha256(data).hexdigest()
                    atomic(self.root / 'sources' / 'wispr-flow' / ('dictionary-' + sha + '.json'), data)
                return count
            finally:
                db.close()

    def sync_transcriber(self, source):
        source = Path(source).expanduser().resolve()
        if not source.is_dir():
            raise FileNotFoundError("Transcriber data directory is unavailable")
        changed = 0
        for path in sorted((source / 'generations').glob('*/metadata.json')):
            stamp = [path.stat().st_mtime_ns, path.stat().st_size]
            key = str(path)
            # Also check destination: a rebuilt cache or manually moved archive must recover.
            if self.state.get(key) == stamp and (self.record_dir('transcriber', path.parent.name) / 'metadata.json').exists():
                continue
            original = json.loads(path.read_text())
            if original['status'] not in ('completed', 'failed', 'cancelled'):
                continue
            if original.get('importedSource'):
                continue  # Wispr history is imported directly and losslessly, not through the server's legacy adapter.
            m = self.load('transcriber', original['id'])
            folder = self.record_dir('transcriber', original['id'])
            m.update(timestamp=original['createdAt'], status=original['status'],
                text={'raw': original.get('rawText'), 'clean': original.get('finalText'),
                      'clean_variant': 'finalText', 'variants': {k:original.get(k) for k in ('rawText','finalText','insertionText','previewText')}},
                context={'app': None, 'device': original.get('device'), 'language': original.get('detectedLanguage')},
                mode=original.get('mode'), selected_source='transcriber')
            self.version(folder, m, original, 'transcriber-metadata', 'metadata.json')
            for field, kind in [('inferenceAudio', 'audio'), ('originalAudio', 'original-audio')]:
                if not original.get(field):
                    continue
                name = original[field]['filename']
                p = (path.parent / name).resolve()
                if not p.is_relative_to(path.parent.resolve()) or not p.is_file():
                    raise ValueError('Transcriber metadata references missing or invalid audio')
                with p.open('rb') as f:
                    self.add_artifact(m, self.blob(folder, f, kind, p.suffix, name))
            self.save(m)
            self.state[key] = stamp
            changed += 1
        self.commit()
        atomic(self.state_path, encode(self.state))
        self.last_sync = now()
        self.last_error = None
        return changed

    def summary(self):
        with self.lock:
            groups = self.db.execute('select source,count(*),sum(audio),sum(screenshot),sum(bytes),sum(timestamp is null) from records group by source').fetchall()
        return {'name': 'Transcripts', 'root': str(self.root), 'sources': [dict(zip(('source','records','audio','screenshots','bytes','undated'), row)) for row in groups],
                'last_transcriber_sync': self.last_sync, 'error': self.last_error, 'artifact_size_limit': None}

    def verify(self):
        count = 0; total = 0
        for p in sorted((self.root / 'records').glob('*/*/metadata.json')):
            m = json.loads(p.read_text())
            for key in ('raw','clean'):
                if (p.parent / (key + '.txt')).read_text() != (m['text'].get(key) or ''):
                    raise ValueError('Transcript file differs from archived metadata')
            for item in m['artifacts'] + m['source_versions']:
                f = (p.parent / item['path']).resolve()
                if not f.is_relative_to(p.parent.resolve()) or not f.is_file() or digest(f) != item['sha256']:
                    raise ValueError('An archive artifact or source version failed integrity verification')
                if 'bytes' in item and f.stat().st_size != item['bytes']:
                    raise ValueError('An archive artifact has the wrong byte count')
                total += f.stat().st_size
            count += 1
        result = {'verified_at': now(), 'records': count, 'verified_bytes': total, 'passed': True}
        atomic(self.root / 'verification.json', encode(result))
        return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', required=True)
    p.add_argument('--cache', required=True)
    sub = p.add_subparsers(dest='command', required=True)
    imp = sub.add_parser('migrate')
    imp.add_argument('--wisprsync', required=True)
    imp.add_argument('--wispr-db', required=True)
    imp.add_argument('--backup', action='append', default=[])
    sub.add_parser('verify')
    sub.add_parser('reindex')
    s = sub.add_parser('sync'); s.add_argument('--transcriber-data', required=True)
    s = sub.add_parser('serve'); s.add_argument('--transcriber-data', required=True); s.add_argument('--port', type=int, default=8392)
    args = p.parse_args()
    os.umask(0o077)
    archive = Archive(args.root, args.cache)
    if args.command == 'migrate':
        report = {'started_at': now(), 'status': 'running'}
        report_path = archive.root / 'migration.json'
        atomic(report_path, encode(report))
        try:
            report['wisprsync_records'] = archive.import_wisprsync(args.wisprsync)
            report['wispr_current_rows'] = archive.import_sqlite(args.wispr_db)
            report['wispr_backup_rows'] = [archive.import_sqlite(b, 'backup') for b in args.backup]
            report['verification'] = archive.verify()
            report['status'] = 'complete'
        except Exception as e:
            report['status'] = 'failed'; report['error'] = str(e)
            raise
        finally:
            report['finished_at'] = now()
            atomic(report_path, encode(report))
        print(json.dumps(report, indent=2))
    elif args.command == 'verify':
        print(json.dumps(archive.verify(), indent=2))
    elif args.command == 'reindex':
        archive.reindex(); print(json.dumps(archive.summary(), indent=2))
    elif args.command == 'sync':
        print('Archived', archive.sync_transcriber(args.transcriber_data), 'Transcriber records')
    elif args.command == 'serve':
        from viewer import serve
        serve(archive, args.transcriber_data, args.port)

if __name__ == '__main__':
    main()
