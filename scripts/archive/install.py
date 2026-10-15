#!/usr/bin/env python3
"""Configure the transcript archive worker for the current login session."""
import argparse
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import time
from archive import atomic, encode


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',required=True)
    parser.add_argument('--launcher-output')
    args=parser.parse_args()
    os.umask(0o077)
    repo=Path(__file__).resolve().parents[2]
    root=Path(args.root).expanduser().resolve()
    if not (root/'dataset.json').is_file():
        raise SystemExit('The archive must exist before installation.')
    config={'archive_root':str(root),'transcriber_data':str(repo/'.local/server'),'viewer_url':'http://127.0.0.1:8392'}
    atomic(repo/'.local/archive-config.json',encode(config))
    label='ai.codecaine.transcriber.archive'
    plist={'Label':label,'ProgramArguments':[sys.executable,str(repo/'scripts/archive/archive.py'),
        '--root',str(root),'--cache',str(repo/'.local/archive-cache'),'serve','--transcriber-data',str(repo/'.local/server')],
        'WorkingDirectory':str(repo),'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':15,
        'StandardOutPath':str(repo/'.local/archive-service.log'),'StandardErrorPath':str(repo/'.local/archive-service.log'),
        'Umask':0o077}
    path=repo/'.local'/f'{label}.plist'
    atomic(path,plistlib.dumps(plist))
    domain=f'gui/{os.getuid()}'
    service=f'{domain}/{label}'
    if subprocess.run(['launchctl','print',service],capture_output=True).returncode==0:
        subprocess.run(['launchctl','bootout',service],check=True)
        # bootout returns before launchd has finished removing the service.
        for _ in range(100):
            if subprocess.run(['launchctl','print',service],capture_output=True).returncode:break
            time.sleep(0.1)
    subprocess.run(['launchctl','bootstrap',domain,str(path)],check=True)
    launcher='''#!/bin/bash
set -euo pipefail
transcriber_root=ROOT
transcriber_domain="gui/$(id -u)"
for transcriber_label in ai.codecaine.transcriber.server ai.codecaine.transcriber.archive; do
    if ! launchctl print "$transcriber_domain/$transcriber_label" >/dev/null 2>&1; then
        launchctl bootstrap "$transcriber_domain" "$transcriber_root/.local/$transcriber_label.plist"
    fi
    launchctl kickstart "$transcriber_domain/$transcriber_label"
done
open /Applications/Transcriber.app
printf 'Transcriber is open. The Data page shows your shared transcript archive.\\n'
'''.replace('ROOT',shlex.quote(str(repo)),1)
    destinations=[repo/'.local/Start Transcriber.command']
    if args.launcher_output:destinations.append(Path(args.launcher_output).expanduser())
    for p in destinations:
        atomic(p,launcher.encode());p.chmod(0o755)
    print('Archive service configured for this login session:',root)

if __name__=='__main__':main()
