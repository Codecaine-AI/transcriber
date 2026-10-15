#!/usr/bin/env python3
"""Build, rebrand, sign, verify, replace, and reopen the local Transcriber app."""
import argparse
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
# macOS permissions, the settings directory, and the Keychain service follow this
# name and identifier. They stay fixed whatever upstream calls its app.
APP_NAME = 'Transcriber'
BUNDLE_ID = 'ai.codecaine.transcriber'
BUILT = ROOT / 'build' / f'{APP_NAME}.app'
# The development build gets the same rebrand under its own name and identifier,
# so its permissions, settings, and Keychain entries stay apart from the real app.
DEV_APP_NAME = 'Transcriber Dev'
DEV_BUNDLE_ID = 'ai.codecaine.transcriber.dev'
DEV_BUILT = ROOT / 'build' / f'{DEV_APP_NAME}.app'
TARGET = Path('/Applications') / f'{APP_NAME}.app'
CONFIG = Path.home() / '.config/transcriber/signing.json'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def requirement(app):
    result = subprocess.run(['codesign', '-d', '-r-', str(app)], check=True, capture_output=True, text=True)
    return next(line.removeprefix('# ') for line in (result.stdout + result.stderr).splitlines()
                if line.removeprefix('# ').startswith('designated =>'))


def installed_pids():
    result = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    executable = str(TARGET / 'Contents/MacOS' / APP_NAME)
    return [int(parts[0]) for line in result.splitlines() if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable]


def build(identity, keychain, dev=False):
    """Build upstream's app unchanged, then give a copy the Transcriber identity."""
    app_name, bundle_id, built = (DEV_APP_NAME, DEV_BUNDLE_ID, DEV_BUILT) if dev else (APP_NAME, BUNDLE_ID, BUILT)
    with ROOT.joinpath('Resources/Info.plist').open('rb') as file:
        base_name = plistlib.load(file)['CFBundleName']
    with ROOT.joinpath('Resources/Info-Dev.plist' if dev else 'Resources/Info.plist').open('rb') as file:
        upstream_name = plistlib.load(file)['CFBundleName']
    run(str(ROOT / 'scripts/build-app.sh'), *(['--dev'] if dev else []), cwd=ROOT)
    upstream_app = ROOT / 'build' / f'{upstream_name}.app'
    stage = Path(tempfile.mkdtemp(prefix='.transcriber.', dir=ROOT / 'build'))
    try:
        app = stage / built.name
        run('ditto', str(upstream_app), str(app))
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        app.joinpath('Contents/MacOS', info['CFBundleExecutable']).rename(app / 'Contents/MacOS' / APP_NAME)
        info.update(CFBundleExecutable=APP_NAME, CFBundleIdentifier=bundle_id,
                    CFBundleName=app_name, CFBundleDisplayName=app_name)
        # Permission prompts name the app and its server ("Transcriber Dev ... your Transcriber server").
        for key, value in info.items():
            if key.endswith('UsageDescription'):
                info[key] = value.replace(upstream_name, app_name).replace(base_name, APP_NAME)
        info_path.write_bytes(plistlib.dumps(info))
        # Upstream's own signature carries the entitlements its build chose.
        entitlements = stage / 'entitlements.plist'
        entitlements.write_bytes(subprocess.run(
            ['codesign', '-d', '--entitlements', '-', '--xml', str(upstream_app)],
            check=True, capture_output=True).stdout)
        if not plistlib.loads(entitlements.read_bytes()):
            raise SystemExit('The upstream build carries no entitlements. No app was changed.')
        # The pinned certificate must succeed; never fall back to ad-hoc signing.
        run('codesign', '--force', '--sign', identity, '--keychain', keychain, '--options', 'runtime',
            '--requirements', f'=designated => identifier "{bundle_id}" and certificate leaf = H"{identity}"',
            '--entitlements', str(entitlements), '--identifier', bundle_id, str(app))
        run('codesign', '--verify', '--deep', '--strict', str(app))
        if built.exists():
            shutil.rmtree(built)
        app.rename(built)
    finally:
        shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only', action='store_true',
                        help=f'Build and sign build/{BUILT.name} without touching the installed app.')
    parser.add_argument('--adopt-identity', action='store_true',
                        help='Allow the one-time switch from the installed identity; permissions need reapproval.')
    parser.add_argument('--dev', action='store_true',
                        help=f'Build and sign build/{DEV_BUILT.name} from the development build. Nothing is installed.')
    args = parser.parse_args()
    if not CONFIG.is_file():
        raise SystemExit('Run python3 scripts/setup-local-signing.py first. No app was changed.')
    config = json.loads(CONFIG.read_text())
    identity = config.get('identity', '')
    if not re.fullmatch('[0-9a-fA-F]{40}', identity):
        raise SystemExit('Invalid signing configuration. No app was changed.')
    ROOT.joinpath('.local').mkdir(exist_ok=True)
    with ROOT.joinpath('.local/install.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another local install is running.')
        if args.dev:
            build(identity, config['keychain'], dev=True)
            expected = f'=identifier "{DEV_BUNDLE_ID}" and certificate leaf = H"{identity}"'
            run('codesign', '--verify', '--strict', '-R', expected, str(DEV_BUILT))
            print('Built and signed:', DEV_BUILT)
            return
        build(identity, config['keychain'])
        expected = f'=identifier "{BUNDLE_ID}" and certificate leaf = H"{identity}"'
        run('codesign', '--verify', '--strict', '-R', expected, str(BUILT))
        if args.build_only:
            print('Built and signed:', BUILT)
            return
        new_requirement = requirement(BUILT)
        if TARGET.is_symlink():
            raise SystemExit('The install target is a symlink. No installed app was changed.')
        if TARGET.exists():
            with TARGET.joinpath('Contents/Info.plist').open('rb') as file:
                if plistlib.load(file).get('CFBundleIdentifier') != BUNDLE_ID:
                    raise SystemExit('A different app occupies the install path.')
            old_requirement = requirement(TARGET)
            if old_requirement != new_requirement and not args.adopt_identity:
                raise SystemExit('The signing identity would change. Use --adopt-identity only for an intentional one-time switch.')
        stage = Path(tempfile.mkdtemp(prefix=f'.{APP_NAME}-install-', dir=TARGET.parent))
        previous = None
        try:
            staged_app = stage / TARGET.name
            run('ditto', str(BUILT), str(staged_app))
            run('codesign', '--verify', '--deep', '--strict', '-R', expected, str(staged_app))
            for pid in installed_pids():
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass
            for _ in range(100):
                if not installed_pids():
                    break
                time.sleep(0.1)
            else:
                raise SystemExit(f'{APP_NAME} did not quit. No app was replaced.')
            if TARGET.exists():
                backup = ROOT / '.local/install-backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
                backup.mkdir(parents=True)
                previous = backup / TARGET.name
                TARGET.rename(previous)
            try:
                staged_app.rename(TARGET)
            except OSError:
                if previous:
                    previous.rename(TARGET)
                raise
            run('open', str(TARGET))
            for _ in range(50):
                if installed_pids():
                    break
                time.sleep(0.1)
            else:
                raise SystemExit(f'App installed but launch was not confirmed. Previous app: {previous}')
            print('Installed and opened:', TARGET)
            print('Stable signing identity:', identity)
            if previous:
                print('Rollback copy:', previous)
            print('No macOS permissions were reset.')
        finally:
            shutil.rmtree(stage)


if __name__ == '__main__':
    main()
