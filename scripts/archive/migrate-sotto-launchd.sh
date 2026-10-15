#!/bin/bash
# One-off swap of the ai.codecaine.sotto.* launchd services for ai.codecaine.transcriber.*.
# The repository folder and every path inside the plists stay as they are.
#
#   migrate-sotto-launchd.sh down                    stop the sotto services, confirm 8391/8392 closed
#   migrate-sotto-launchd.sh preview --backup DIR    generate the new plists into DIR only; touches nothing else
#   migrate-sotto-launchd.sh up --backup DIR         install and start the transcriber services
#   migrate-sotto-launchd.sh rollback --backup DIR   stop the transcriber services, restore and start the sotto ones
#
# DIR is the migrate-sotto.py backup directory; its launchd/ and repo-local/ copies are the source of truth.
set -euo pipefail

die() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 2
}
say() { printf '[%s] %s\n' "$1" "$2"; }

command=${1:-}
[[ $# -gt 0 ]] && shift
backup=""
while [[ $# -gt 0 ]]; do
    case $1 in
    --backup)
        [[ $# -ge 2 && -d $2 ]] || die "--backup needs an existing directory"
        backup=$(cd "$2" && pwd -P)
        shift 2
        ;;
    *) die "unknown argument: $1" ;;
    esac
done

domain="gui/$(id -u)"
labels=(server archive app)
local_labels=(archive server)
agents="$HOME/Library/LaunchAgents"

loaded() { launchctl print "$domain/$1" >/dev/null 2>&1; }
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | tr '\n' ' ' || true; }

field() { # field NAME: read a value from DIR/backup.json
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$backup/backup.json" "$1"
}
journal() { # journal KEY: read a value from DIR/journal.json, empty when absent
    python3 -c 'import json,sys,os; p=sys.argv[1]; print(json.load(open(p)).get(sys.argv[2]) or "" if os.path.exists(p) else "")' \
        "$backup/journal.json" "$1"
}

stop_labels() { # stop_labels PREFIX
    local prefix=$1 label target
    for label in "${labels[@]}"; do
        target="$domain/ai.codecaine.$prefix.$label"
        if loaded "ai.codecaine.$prefix.$label"; then
            launchctl bootout "$target" || die "bootout $target failed"
            say did "bootout $target"
        fi
    done
    for _ in $(seq 100); do
        local busy=0
        for label in "${labels[@]}"; do
            if loaded "ai.codecaine.$prefix.$label"; then busy=1; fi
        done
        for port in 8391 8392; do
            if [[ -n $(listeners "$port") ]]; then busy=1; fi
        done
        if [[ $busy -eq 0 ]]; then break; fi
        sleep 0.2
    done
    for label in "${labels[@]}"; do
        ! loaded "ai.codecaine.$prefix.$label" || die "ai.codecaine.$prefix.$label is still loaded"
    done
    for port in 8391 8392; do
        [[ -z $(listeners "$port") ]] || die "port $port is still in use by: $(listeners "$port")"
    done
    say ok "ai.codecaine.$prefix.* stopped; ports 8391 and 8392 closed"
}

require_quiet() {
    local prefix label
    for prefix in sotto transcriber; do
        for label in "${labels[@]}"; do
            ! loaded "ai.codecaine.$prefix.$label" || die "ai.codecaine.$prefix.$label is loaded; run down first"
        done
    done
    for port in 8391 8392; do
        [[ -z $(listeners "$port") ]] || die "port $port is in use by: $(listeners "$port")"
    done
}

require_backup() {
    [[ -n $backup && -f $backup/backup.json ]] || die "pass --backup DIR from migrate-sotto.py backup"
    [[ $(field status) == complete ]] || die "backup is incomplete"
    repo=$(field repo)
    for label in "${labels[@]}"; do
        [[ -f $backup/launchd/LaunchAgents/ai.codecaine.sotto.$label.plist ]] || die "backup lacks ai.codecaine.sotto.$label.plist"
    done
}

generate() { # generate OUT: build the transcriber plists and launcher from the backed-up sotto copies
    local out=$1
    rm -rf "$out"
    mkdir -p "$out/LaunchAgents" "$out/repo-local"
    python3 - "$backup" "$out" "$repo" "$(field transcripts)" <<'PY'
import copy, plistlib, sys
from pathlib import Path
backup, out, repo, transcripts = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]

def walk(value):
    if isinstance(value, dict):
        for v in value.values(): yield from walk(v)
    elif isinstance(value, list):
        for v in value: yield from walk(v)
    elif isinstance(value, str):
        yield value

def convert(src, dst, label):
    old = plistlib.loads(src.read_bytes())
    new = copy.deepcopy(old)
    assert new['Label'] == f'ai.codecaine.sotto.{label}', (src, new['Label'])
    new['Label'] = f'ai.codecaine.transcriber.{label}'
    args = new.get('ProgramArguments', [])
    flags = [i for i, a in enumerate(args) if a == '--sotto-data']
    assert len(flags) == (1 if label == 'archive' else 0), (src, flags)
    for i in flags:
        args[i] = '--transcriber-data'
    # Only the label and the flag may change; any other sotto must be the repo or archive path.
    for s in walk(new):
        assert 'sotto' not in s or any(s == p or s.startswith(p + '/') for p in (repo, transcripts)), (src, s)
    changed = [k for k in set(old) | set(new) if old.get(k) != new.get(k)]
    assert set(changed) <= {'Label', 'ProgramArguments'}, changed
    dst.write_bytes(plistlib.dumps(new, fmt=plistlib.FMT_XML))
    print(f'    {src.name} -> {dst.name}: Label' + (', --sotto-data -> --transcriber-data' if flags else ''))

for label in ('server', 'archive', 'app'):
    convert(backup / 'launchd/LaunchAgents' / f'ai.codecaine.sotto.{label}.plist',
            out / 'LaunchAgents' / f'ai.codecaine.transcriber.{label}.plist', label)
for label in ('archive', 'server'):
    src = backup / 'repo-local' / f'ai.codecaine.sotto.{label}.plist'
    if src.is_file():
        convert(src, out / 'repo-local' / f'ai.codecaine.transcriber.{label}.plist', label)

src = backup / 'repo-local' / 'Start Transcriber.command'
if src.is_file():
    text = src.read_text()
    new = text.replace('ai.codecaine.sotto.', 'ai.codecaine.transcriber.')
    for name in ('root', 'domain', 'label'):
        new = new.replace(f'sotto_{name}', f'transcriber_{name}')
    leftover = [line for line in new.splitlines() if 'sotto' in line and not line.startswith('transcriber_root=')]
    assert not leftover, leftover
    (out / 'repo-local' / 'Start Transcriber.command').write_text(new)
    print('    Start Transcriber.command: labels and variable names renamed; repo path unchanged')
PY
    local f
    for f in "$out"/LaunchAgents/*.plist "$out"/repo-local/*.plist; do
        plutil -lint "$f" >/dev/null || die "plutil -lint failed for $f"
    done
    say ok "generated and linted $(ls "$out"/LaunchAgents "$out"/repo-local | grep -c '\.plist$') plists in $out"
    for label in "${labels[@]}"; do
        printf '    --- diff ai.codecaine.sotto.%s -> transcriber (plutil -p)\n' "$label"
        diff <(plutil -p "$backup/launchd/LaunchAgents/ai.codecaine.sotto.$label.plist") \
            <(plutil -p "$out/LaunchAgents/ai.codecaine.transcriber.$label.plist") | sed 's/^/    /' || true
    done
    if [[ -f "$out/repo-local/Start Transcriber.command" ]]; then
        printf '    --- diff Start Transcriber.command\n'
        diff "$backup/repo-local/Start Transcriber.command" "$out/repo-local/Start Transcriber.command" | sed 's/^/    /' || true
    fi
}

place() { # place NEW_FILE DEST MODE: install a generated file, refusing to overwrite something different
    if [[ -e $2 ]]; then
        cmp -s "$1" "$2" || die "$2 exists and differs from the generated file"
        return
    fi
    cp "$1" "$2"
    chmod "$3" "$2"
    say did "installed $2"
}

stash() { # stash FILE DEST_DIR [ORIGINAL]: move FILE into the backup, refusing if it differs from ORIGINAL
    [[ -e $1 ]] || return 0
    if [[ -n ${3:-} ]]; then cmp -s "$1" "$3" || die "$1 changed since the backup; resolve by hand"; fi
    mkdir -p "$2"
    [[ ! -e $2/$(basename "$1") ]] || die "$2/$(basename "$1") already exists"
    mv "$1" "$2/"
    say did "moved $1 -> $2/"
}

health() { # health SOURCE: wait for the server and the archive viewer; SOURCE is the expected archive source id
    local source=$1 expected
    expected=$(field records)
    for _ in $(seq 120); do
        curl -fsS -m 2 -o /dev/null http://127.0.0.1:8391/v1/health 2>/dev/null && break
        sleep 1
    done
    curl -fsS -m 2 -o /dev/null http://127.0.0.1:8391/v1/health || die "server health on 8391 did not answer"
    say ok "server answers on http://127.0.0.1:8391/v1/health"
    local summary=""
    for _ in $(seq 120); do
        summary=$(curl -fsS -m 5 http://127.0.0.1:8392/api/summary 2>/dev/null || true)
        if [[ -n $summary ]] && python3 - "$summary" "$source" "$expected" <<'PY'; then break; fi
import json, sys
d, source, expected = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
counts = {s['source']: s['records'] for s in d['sources']}
sync = d.get(f'last_{source}_sync')
sys.exit(0 if counts.get(source, 0) >= expected and set(counts) == {source, 'wispr-flow'} and sync and not d['error'] else 1)
PY
        summary=""
        sleep 1
    done
    [[ -n $summary ]] || die "archive viewer on 8392 never reported $expected $source records with a clean sync"
    say ok "archive viewer on 8392: $summary"
}

case $command in
down)
    stop_labels sotto
    ;;
preview)
    require_backup
    generate "$backup/launchd/preview"
    say PASS "preview only; nothing outside $backup changed"
    ;;
up)
    require_backup
    [[ $(field launch_agents) == "$agents" ]] || die "backup was taken for another LaunchAgents folder"
    [[ $(journal status) == complete && -n $(journal verified_at) ]] ||
        die "run migrate-sotto.py migrate and verify (both passing) before up"
    grep -q "'--transcriber-data'" "$repo/scripts/archive/archive.py" ||
        die "$repo/scripts/archive/archive.py is still the sotto code; merge the rename first"
    require_quiet
    generate "$backup/launchd/new"
    for label in "${labels[@]}"; do
        place "$backup/launchd/new/LaunchAgents/ai.codecaine.transcriber.$label.plist" \
            "$agents/ai.codecaine.transcriber.$label.plist" 600
        stash "$agents/ai.codecaine.sotto.$label.plist" "$backup/launchd/moved/LaunchAgents" \
            "$backup/launchd/LaunchAgents/ai.codecaine.sotto.$label.plist"
    done
    for label in "${local_labels[@]}"; do
        if [[ -f $backup/launchd/new/repo-local/ai.codecaine.transcriber.$label.plist ]]; then
            place "$backup/launchd/new/repo-local/ai.codecaine.transcriber.$label.plist" \
                "$repo/.local/ai.codecaine.transcriber.$label.plist" 600
        fi
        stash "$repo/.local/ai.codecaine.sotto.$label.plist" "$backup/launchd/moved/repo-local" \
            "$backup/repo-local/ai.codecaine.sotto.$label.plist"
    done
    stash "$repo/.local/Start Transcriber.command" "$backup/launchd/moved/repo-local" \
        "$backup/repo-local/Start Transcriber.command"
    place "$backup/launchd/new/repo-local/Start Transcriber.command" "$repo/.local/Start Transcriber.command" 755
    stash "$repo/.local/Start Sotto.command" "$backup/launchd/moved/repo-local" "$backup/repo-local/Start Sotto.command"
    for label in "${labels[@]}"; do
        launchctl bootstrap "$domain" "$agents/ai.codecaine.transcriber.$label.plist" ||
            die "bootstrap ai.codecaine.transcriber.$label failed; run rollback"
        say did "bootstrap ai.codecaine.transcriber.$label"
    done
    health transcriber
    say PASS "ai.codecaine.transcriber.* running"
    ;;
rollback)
    require_backup
    [[ $(field launch_agents) == "$agents" ]] || die "backup was taken for another LaunchAgents folder"
    stop_labels transcriber
    status=$(journal status)
    [[ -z $status || $status == new || $status == rolled-back ]] ||
        die "archive journal is '$status': run migrate-sotto.py rollback first (services stay stopped)"
    grep -q "'--sotto-data'" "$repo/scripts/archive/archive.py" ||
        die "$repo/scripts/archive/archive.py is the transcriber code; revert the rename in the main checkout, then rerun (services stay stopped)"
    for label in "${labels[@]}"; do
        stash "$agents/ai.codecaine.transcriber.$label.plist" "$backup/launchd/rolled-back/LaunchAgents"
        place "$backup/launchd/LaunchAgents/ai.codecaine.sotto.$label.plist" "$agents/ai.codecaine.sotto.$label.plist" 600
    done
    for label in "${local_labels[@]}"; do
        stash "$repo/.local/ai.codecaine.transcriber.$label.plist" "$backup/launchd/rolled-back/repo-local"
        if [[ -f $backup/repo-local/ai.codecaine.sotto.$label.plist ]]; then
            place "$backup/repo-local/ai.codecaine.sotto.$label.plist" "$repo/.local/ai.codecaine.sotto.$label.plist" 600
        fi
    done
    if [[ -f "$repo/.local/Start Transcriber.command" ]] &&
        ! cmp -s "$repo/.local/Start Transcriber.command" "$backup/repo-local/Start Transcriber.command"; then
        stash "$repo/.local/Start Transcriber.command" "$backup/launchd/rolled-back/repo-local"
    fi
    for name in "Start Transcriber.command" "Start Sotto.command"; do
        if [[ -f $backup/repo-local/$name ]]; then place "$backup/repo-local/$name" "$repo/.local/$name" 755; fi
    done
    for label in "${labels[@]}"; do
        launchctl bootstrap "$domain" "$agents/ai.codecaine.sotto.$label.plist" ||
            die "bootstrap ai.codecaine.sotto.$label failed"
        say did "bootstrap ai.codecaine.sotto.$label"
    done
    health sotto
    say PASS "ai.codecaine.sotto.* restored and running"
    ;;
*)
    sed -n '2,10p' "$0"
    exit 2
    ;;
esac
