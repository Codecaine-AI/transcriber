#!/usr/bin/env python3
"""Swap the repository path in the files Phase 2 moves: rewrite-repo-paths.py OLD NEW FILE...

Handles launchd plists, Start Transcriber.command, archive-config.json and transcriber-state.json (and an
installation.json, whose paths get the same prefix swap). Every file is rewritten atomically with its mode kept. Exits non-zero if a
file is missing or still names OLD afterwards. Run with OLD and NEW swapped to undo.
"""
import difflib
import json
import os
import plistlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from archive import atomic, encode  # noqa: E402


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    old, new = sys.argv[1].rstrip('/'), sys.argv[2].rstrip('/')

    def swap(value):
        if isinstance(value, str):
            return new + value[len(old):] if value == old or value.startswith(old + '/') else value
        if isinstance(value, list):
            return [swap(v) for v in value]
        if isinstance(value, dict):
            return {swap(k): swap(v) for k, v in value.items()}
        return value

    missing = [name for name in sys.argv[3:] if not Path(name).is_file()]
    if missing:  # check them all before changing any
        raise SystemExit(f'[FAIL] missing {missing}')
    rewritten = unchanged = 0
    for name in sys.argv[3:]:
        p = Path(name)
        before = p.read_bytes()
        mode = p.stat().st_mode & 0o777
        if p.suffix == '.plist':
            after = plistlib.dumps(swap(plistlib.loads(before)), fmt=plistlib.FMT_XML)
        elif p.name == 'transcriber-state.json':
            data = json.loads(before)
            moved = swap(data)
            if len(moved) != len(data) or not all(k.startswith(new + '/.local/server/generations/') for k in moved):
                raise SystemExit(f'[FAIL] {p}: a state key is outside {new}/.local/server/generations/')
            after = encode(moved)
        elif p.name == 'archive-config.json':
            after = encode(swap(json.loads(before)))
        elif p.name == 'installation.json':  # same swap: a historical path outside the repo stays as it is
            data = json.loads(before)
            moved = swap(data)
            after = before if moved == data else \
                (json.dumps(moved, indent=2, ensure_ascii=False) + ('\n' if before.endswith(b'\n') else '')).encode()
        elif p.name == 'Start Transcriber.command':
            text = before.decode()
            line = f'transcriber_root={old}\n'
            if text.count(line) != 1:
                raise SystemExit(f'[FAIL] {p}: expected one line {line.strip()!r}')
            after = text.replace(line, f'transcriber_root={new}\n').encode()
        else:
            raise SystemExit(f'[FAIL] {p}: not a file this tool knows')
        if old.encode() in after:
            raise SystemExit(f'[FAIL] {p} still names {old} after the rewrite')
        if after == before:
            unchanged += 1
            print(f'    unchanged {p}')
            continue
        atomic(p, after)
        os.chmod(p, mode)
        rewritten += 1
        if p.name == 'transcriber-state.json':
            print(f'    rewrote {p}: {len(json.loads(after))} keys')
        else:
            print(f'    rewrote {p}')
            for d in difflib.unified_diff(before.decode().splitlines(), after.decode().splitlines(), lineterm='', n=0):
                if d[:1] in '+-' and d[:3] not in ('+++', '---'):
                    print('      ' + d)
    print(f'[ok] {rewritten} rewritten, {unchanged} unchanged (no repository path inside)')


if __name__ == '__main__':
    main()
