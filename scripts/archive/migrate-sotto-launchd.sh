#!/bin/bash
# One-off swap of the ai.codecaine.sotto.* launchd services for ai.codecaine.transcriber.*.
# The repository folder and every path inside the plists stay as they are. DIR is the migration directory;
# migrate-sotto.py backup --dest DIR uses the same one.
#
#   down --dir DIR      quit the app, drain the server and the archive worker, stop the sotto services and move
#                       their plists into DIR, so nothing starts again at login or after a reboot
#   preview --dir DIR   write the transcriber plists into DIR/launchd/preview only
#   up --dir DIR        after migrate + verify passed and main has the new code: install and start transcriber
#   stop --dir DIR      the same drain-and-stop for the transcriber services (before an archive rollback, and
#                       Phase 2's folder move); their plists move into DIR/launchd/stopped
#   start --dir DIR     reinstall the plists from DIR/launchd/stopped and start the transcriber services again
#   rollback --dir DIR  restore and start the sotto services: after migrate-sotto.py rollback passed, or when no
#                       migration step ran (backup or plan refused after down). Main must run the sotto code.
#
# Every command is safe to rerun after an interruption; already-stopped services count as stopped, and stashed
# plists stay in DIR until the services they start pass the health check. DIR/launchd/journal.log records progress.
#
# Guards against an accidental start while data moves: the plists leave ~/Library/LaunchAgents and the labels are
# disabled (primary guard, since the old code cannot read new files), and <cache>/migration.lock makes the new
# archive worker, install.py and Start Transcriber.command refuse to run (secondary guard).
set -euo pipefail

die() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 2
}
say() { printf '[%s] %s\n' "$1" "$2"; }

command=${1:-}
[[ $# -gt 0 ]] && shift
dir=""
while [[ $# -gt 0 ]]; do
    case $1 in
    --dir)
        [[ $# -ge 2 ]] || die "--dir needs a directory"
        mkdir -p "$2"
        dir=$(cd "$2" && pwd -P)
        shift 2
        ;;
    *) die "unknown argument: $1" ;;
    esac
done
[[ -n $dir || -z $command ]] || die "pass --dir DIR"
ORDER='plan -> down -> plan --dir -> backup -> migrate -> verify -> merge into main -> up'

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# Scratch rehearsals only: point at copies. Real runs use the defaults.
agents=${MIGRATE_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
repo=${MIGRATE_REPO:-$(dirname "$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir)")}
transcripts=${MIGRATE_TRANSCRIPTS:-$HOME/Transcripts}
[[ -z ${MIGRATE_LAUNCH_AGENTS:-}${MIGRATE_REPO:-}${MIGRATE_TRANSCRIPTS:-} ]] ||
    say scratch "agents=$agents repo=$repo transcripts=$transcripts"
uid=$(id -u)
domain="gui/$uid"
labels=(server archive app)
lock="$repo/.local/archive-cache/migration.lock"
app_id=ai.codecaine.transcriber

on_exit() { # on any failure or interruption: where things stand, and the exact commands to continue
    local rc=$? p label plist
    trap - EXIT INT TERM
    if [[ $rc -ne 0 && -n $command && -n $dir ]]; then
        printf '\n[RECOVER] %s stopped (exit %s). Current state:\n' "$command" "$rc"
        for p in sotto transcriber; do
            for label in "${labels[@]}"; do
                plist="$agents/ai.codecaine.$p.$label.plist"
                printf '    ai.codecaine.%-18s %-10s plist %s\n' "$p.$label" \
                    "$(loaded "ai.codecaine.$p.$label" && echo loaded || echo stopped)" \
                    "$([[ -f $plist ]] && echo installed || echo 'not installed')"
            done
        done
        printf '    lock %s\n' "$([[ -e $lock ]] && echo "present: $lock" || echo absent)"
        printf '  Every step is safe to rerun. Retry:  bash %s %s --dir %s\n' "$0" "$command" "$dir"
        case $command in
        down) printf '  Or go back to the sotto services:  bash %s rollback --dir %s\n' "$0" "$dir" ;;
        up | start) printf '  Or stop the transcriber services again:  bash %s stop --dir %s\n' "$0" "$dir" ;;
        stop) printf '  Or start the transcriber services again:  bash %s start --dir %s\n' "$0" "$dir" ;;
        esac
        p=sotto
        [[ $command == up || $command == start || $command == stop ]] && p=transcriber
        printf '  Last resort, by hand (%s services):\n' "$p"
        for label in "${labels[@]}"; do
            plist="$agents/ai.codecaine.$p.$label.plist"
            [[ -f $plist ]] || for stashed in "$dir/launchd/LaunchAgents" "$dir/launchd/stopped/LaunchAgents"; do
                [[ -f $stashed/ai.codecaine.$p.$label.plist ]] && printf '    cp -p %q %q\n' "$stashed/ai.codecaine.$p.$label.plist" "$plist" && break
            done
            printf '    launchctl enable %s/ai.codecaine.%s.%s; launchctl bootstrap %s %q\n' "$domain" "$p" "$label" "$domain" "$plist"
        done
        [[ $p == transcriber ]] && printf '    rm -f %q   # the transcriber worker refuses to run while this lock exists\n' "$lock"
    fi
    exit $rc
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

loaded() { launchctl print "$domain/$1" >/dev/null 2>&1; }
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | tr '\n' ' ' || true; }
tool() { python3 "$script_dir/migrate-sotto.py" --repo "$repo" --transcripts "$transcripts" "$@"; }
app_running() { [[ $(osascript -e "application id \"$app_id\" is running" 2>/dev/null) == true ]]; }
journal() {
    python3 -c 'import json,sys,os; p=sys.argv[1]; print((json.load(open(p)).get(sys.argv[2]) or "") if os.path.exists(p) else "")' \
        "$dir/journal.json" "$1"
}
backup_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$dir/backup.json" "$1"; }

wait_until() { # wait_until SECONDS DESCRIPTION COMMAND...: poll every 2 s, fail with DESCRIPTION on timeout
    local seconds=$1 what=$2
    shift 2
    local deadline=$((SECONDS + seconds))
    until "$@"; do
        [[ $SECONDS -lt $deadline ]] || die "timed out after ${seconds}s waiting for: $what"
        sleep 2
    done
}

drained() { # drained NAMESPACE FIELD...: every listed drain-status field is 0
    local status ns=$1
    shift
    status=$(tool drain-status --namespace "$ns" || true)
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(any(d[k] for k in sys.argv[2:] + ["unreadable"]))' "$status" "$@" ||
        {
            printf '    waiting: %s\n' "$status"
            return 1
        }
}

ports_closed() { [[ -z $(listeners 8391)$(listeners 8392) ]]; }
labels_gone() { # labels_gone PREFIX
    local label
    for label in "${labels[@]}"; do
        if loaded "ai.codecaine.$1.$label"; then return 1; fi
    done
}

place() { # place SRC DEST MODE: copy into place, refusing to replace a different file
    if [[ ! -e $1 && -e $2 ]]; then return 0; fi # an earlier run already placed it and moved the source on
    [[ -e $1 ]] || die "neither $1 nor $2 exists"
    if [[ -e $2 ]]; then
        cmp -s "$1" "$2" || die "$2 exists and differs from $1"
        return 0
    fi
    cp "$1" "$2.migrate-tmp"
    chmod "$3" "$2.migrate-tmp"
    mv "$2.migrate-tmp" "$2"
    say did "installed $2"
}

stash() { # stash FILE DESTDIR: copy FILE into DESTDIR, then remove it. Safe to rerun after an interruption.
    local target
    target="$2/$(basename "$1")"
    [[ -e $1 ]] || return 0
    mkdir -p "$2"
    if [[ -e $target ]]; then
        cmp -s "$1" "$target" || die "$target exists and differs from $1"
    else
        cp -p "$1" "$target.migrate-tmp"
        mv "$target.migrate-tmp" "$target"
    fi
    rm "$1"
    say did "moved $1 -> $2/"
}

note() { # note TEXT: append to DIR/launchd/journal.log
    mkdir -p "$dir/launchd"
    printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$command" "$*" >>"$dir/launchd/journal.log"
}

bootstrap() { # bootstrap PREFIX: load the three labels; already-loaded labels are left alone
    local label
    for label in "${labels[@]}"; do
        if loaded "ai.codecaine.$1.$label"; then
            say skip "ai.codecaine.$1.$label already loaded"
        else
            launchctl bootstrap "$domain" "$agents/ai.codecaine.$1.$label.plist"
            say did "bootstrap ai.codecaine.$1.$label"
        fi
    done
}

stop_label() { # stop_label LABEL: bootout (if loaded) and disable
    if loaded "$1"; then
        launchctl bootout "$domain/$1"
        say did "bootout $1"
    fi
    launchctl disable "$domain/$1"
    wait_until 30 "$1 to unload" eval "! loaded $1"
}

drain_and_stop() { # drain_and_stop PREFIX DESTDIR: idempotent; already-stopped services count as stopped
    local prefix=$1 dest=$2 label
    mkdir -p "$dest"
    if [[ ! -f $dir/launchd/disabled-before.txt ]]; then
        launchctl print-disabled "$domain" | grep -E 'ai\.codecaine\.(sotto|transcriber)\.' >"$dir/launchd/disabled-before.txt" || true
    fi
    say info "a dictation still being recorded when the app quits is kept in Recovered Recordings, not lost"
    local attempt
    for attempt in 1 2 3; do
        if app_running; then
            wait_until 180 "the current dictation to finish uploading (do not start a new one)" drained "$prefix" receiving
            osascript -e "tell application id \"$app_id\" to quit" >/dev/null
            wait_until 60 "Transcriber.app to quit" eval '! app_running'
            say ok "Transcriber.app quit (no new takes)"
        fi
        # The server runs until it is idle, then stops, so nothing it holds can be cancelled.
        if loaded "ai.codecaine.$prefix.server"; then
            wait_until 900 "the server to finish every queued and in-progress take" drained "$prefix" in_flight
        else
            drained "$prefix" in_flight || die "the server is stopped with unfinished takes; start it to finish them"
        fi
        if ! app_running; then break; fi
        say info "Transcriber.app reopened (a Login Item?); quitting it again before the server stops"
    done
    ! app_running || die "Transcriber.app keeps reopening; quit it and remove its Login Item, then rerun"
    say ok "server has no unfinished takes and the app is closed"
    stop_label "ai.codecaine.$prefix.server"
    note "server stopped"
    # The archive worker keeps running until it has copied every finished take.
    if loaded "ai.codecaine.$prefix.archive"; then
        wait_until 120 "the archive worker to copy every finished take" drained "$prefix" in_flight unarchived
    else
        drained "$prefix" in_flight unarchived || die "the archive worker is stopped with uncopied takes; start it first"
    fi
    say ok "archive worker has copied every finished take"
    mkdir -p "$(dirname "$lock")"
    [[ -e $lock ]] || printf 'migration started %s\n' "$(date -u +%FT%TZ)" >"$lock"
    say did "lock $lock"
    stop_label "ai.codecaine.$prefix.archive"
    stop_label "ai.codecaine.$prefix.app"
    wait_until 30 "ports 8391 and 8392 to close" ports_closed
    for label in "${labels[@]}"; do stash "$agents/ai.codecaine.$prefix.$label.plist" "$dest/LaunchAgents"; done
    for label in archive server; do stash "$repo/.local/ai.codecaine.$prefix.$label.plist" "$dest/repo-local"; done
    stash "$repo/.local/Start Transcriber.command" "$dest/repo-local"
    stash "$repo/.local/Start Sotto.command" "$dest/repo-local"
    note "stopped and stashed $prefix"
    say ok "ai.codecaine.$prefix.* stopped and disabled; plists in $dest"
}

generate() { # generate OUT: transcriber plists from the sotto copies in DIR/launchd, launcher from install.py
    local out=$1 f
    rm -rf "$out"
    mkdir -p "$out/LaunchAgents" "$out/repo-local"
    python3 - "$dir/launchd" "$out" "$repo" "$transcripts" "$script_dir" <<'PY'
import copy, plistlib, sys
from pathlib import Path
src_root, out, repo, transcripts, scripts = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
sys.path.insert(0, scripts)
from install import launcher_text

def strings(value):
    if isinstance(value, dict):
        for v in value.values(): yield from strings(v)
    elif isinstance(value, list):
        for v in value: yield from strings(v)
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
    for s in strings(new):  # any remaining sotto must be the unchanged repo or archive path
        assert 'sotto' not in s or any(s == p or s.startswith(p + '/') for p in (repo, transcripts)), (src, s)
    assert {k for k in set(old) | set(new) if old.get(k) != new.get(k)} <= {'Label', 'ProgramArguments'}
    dst.write_bytes(plistlib.dumps(new, fmt=plistlib.FMT_XML))
    print(f'    {src.name} -> {dst.name}')

for label in ('server', 'archive', 'app'):
    convert(src_root / 'LaunchAgents' / f'ai.codecaine.sotto.{label}.plist',
            out / 'LaunchAgents' / f'ai.codecaine.transcriber.{label}.plist', label)
for label in ('archive', 'server'):
    src = src_root / 'repo-local' / f'ai.codecaine.sotto.{label}.plist'
    if src.is_file():
        convert(src, out / 'repo-local' / f'ai.codecaine.transcriber.{label}.plist', label)
(out / 'repo-local' / 'Start Transcriber.command').write_text(launcher_text(repo))
print('    Start Transcriber.command from install.py (checks the migration lock)')
PY
    for f in "$out"/LaunchAgents/*.plist "$out"/repo-local/*.plist; do
        plutil -lint "$f" >/dev/null || die "plutil -lint failed for $f"
    done
    for f in "$out"/LaunchAgents/*.plist; do
        printf '    --- %s\n' "$(basename "$f")"
        diff <(plutil -p "$dir/launchd/LaunchAgents/$(basename "$f" | sed 's/transcriber/sotto/')") <(plutil -p "$f") |
            sed 's/^/    /' || true
    done
    say ok "generated and linted the transcriber plists in $out"
}

health() { # health SOURCE
    local source=$1 expected body=""
    expected=$(find "$transcripts/records/$source" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    ready() {
        body=$(curl -fsS -m 3 http://127.0.0.1:8391/v1/health 2>/dev/null) || return 1
        python3 -c 'import json,sys; sys.exit(json.loads(sys.argv[1]).get("ready") is not True)' "$body"
    }
    wait_until 240 "server health ready:true on 8391" ready
    say ok "server ready on 8391"
    archive_ok() {
        body=$(curl -fsS -m 5 http://127.0.0.1:8392/api/summary 2>/dev/null) || return 1
        python3 - "$body" "$source" "$expected" <<'PY'
import json, sys
d, source, expected = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
counts = {s['source']: s['records'] for s in d['sources']}
ok = counts.get(source, 0) >= expected and set(counts) == {source, 'wispr-flow'}
sys.exit(0 if ok and d.get(f'last_{source}_sync') and not d.get('error') else 1)
PY
    }
    wait_until 240 "archive viewer on 8392 to report $expected $source records and a clean sync" archive_ok
    say ok "archive viewer on 8392: $body"
}

restore_enabled() { # restore_enabled PREFIX: enable labels unless they were disabled before the migration
    local label file="$dir/launchd/disabled-before.txt"
    for label in "${labels[@]}"; do
        if grep -q "\"ai.codecaine.$1.$label\" => disabled" "$file" 2>/dev/null; then
            say keep "ai.codecaine.$1.$label stays disabled as it was before"
        else
            launchctl enable "$domain/ai.codecaine.$1.$label"
        fi
    done
}

case $command in
down)
    say info "run order: $ORDER"
    grep -q "'--sotto-data'" "$repo/scripts/archive/archive.py" ||
        die "$repo/scripts/archive/archive.py already has the transcriber code: the rename was merged before down. Revert the merge in the main checkout, then run in order: $ORDER"
    for label in "${labels[@]}"; do
        [[ -f $agents/ai.codecaine.sotto.$label.plist || -f $dir/launchd/LaunchAgents/ai.codecaine.sotto.$label.plist ]] ||
            die "ai.codecaine.sotto.$label.plist is neither installed nor stashed in $dir"
    done
    drain_and_stop sotto "$dir/launchd"
    for label in "${labels[@]}"; do stop_label "ai.codecaine.transcriber.$label"; done # nothing may start in between
    say PASS "down. Next: migrate-sotto.py plan --dir $dir, then backup --dest $dir.
       To go back instead (before migrate): migrate-sotto-launchd.sh rollback --dir $dir"
    ;;
preview)
    generate "$dir/launchd/preview"
    say PASS "preview only; nothing outside $dir changed"
    ;;
up)
    [[ -f $dir/backup.json && $(journal status) == complete && -n $(journal verified_at) ]] ||
        die "run migrate-sotto.py backup, migrate and verify (all passing) first"
    [[ $(backup_field launch_agents) == "$agents" ]] || die "the backup was taken for another LaunchAgents folder"
    grep -q "'--transcriber-data'" "$repo/scripts/archive/archive.py" ||
        die "$repo/scripts/archive/archive.py is still the sotto code; merge the rename first"
    labels_gone sotto || die "a sotto label is loaded"
    python3 - "$dir" <<'PY' || die "files in $dir/launchd differ from the backup record"
import hashlib, json, sys
from pathlib import Path
d = Path(sys.argv[1])
recorded = json.load(open(d / 'backup.json'))['launchd']
actual = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((d / 'launchd/LaunchAgents').iterdir())}
sys.exit(recorded != actual)
PY
    generate "$dir/launchd/new"
    for label in "${labels[@]}"; do
        place "$dir/launchd/new/LaunchAgents/ai.codecaine.transcriber.$label.plist" "$agents/ai.codecaine.transcriber.$label.plist" 600
    done
    for label in archive server; do
        if [[ -f $dir/launchd/new/repo-local/ai.codecaine.transcriber.$label.plist ]]; then
            place "$dir/launchd/new/repo-local/ai.codecaine.transcriber.$label.plist" "$repo/.local/ai.codecaine.transcriber.$label.plist" 600
        fi
    done
    place "$dir/launchd/new/repo-local/Start Transcriber.command" "$repo/.local/Start Transcriber.command" 755
    restore_enabled transcriber
    rm -f "$lock"
    say did "removed $lock"
    bootstrap transcriber
    health transcriber
    note "up: transcriber running"
    say PASS "ai.codecaine.transcriber.* running; the sotto labels stay disabled with their plists in $dir/launchd"
    ;;
stop)
    for label in "${labels[@]}"; do
        [[ -f $agents/ai.codecaine.transcriber.$label.plist || -f $dir/launchd/stopped/LaunchAgents/ai.codecaine.transcriber.$label.plist ]] ||
            die "ai.codecaine.transcriber.$label.plist is neither installed nor stashed in $dir/launchd/stopped"
    done
    drain_and_stop transcriber "$dir/launchd/stopped"
    say PASS "transcriber services stopped and disabled; plists in $dir/launchd/stopped"
    ;;
start)
    status=$(journal status)
    if [[ -n $status || -f $dir/backup.json ]]; then # Phase 1 directory; Phase 2 work directories have no journal
        [[ $status == complete && -n $(journal verified_at) ]] ||
            die "the archive journal is '${status:-missing}': start needs a migrated and verified archive (verify --backup $dir)"
    fi
    stopped="$dir/launchd/stopped"
    grep -q "'--transcriber-data'" "$repo/scripts/archive/archive.py" || die "$repo runs the sotto archive code"
    labels_gone sotto || die "a sotto label is loaded"
    for label in "${labels[@]}"; do # each label may still be stashed or already installed by an earlier run
        place "$stopped/LaunchAgents/ai.codecaine.transcriber.$label.plist" "$agents/ai.codecaine.transcriber.$label.plist" 600
        plutil -lint "$agents/ai.codecaine.transcriber.$label.plist" >/dev/null || die "plutil -lint failed"
    done
    for label in archive server; do
        f="$stopped/repo-local/ai.codecaine.transcriber.$label.plist"
        if [[ -f $f || -f $repo/.local/$(basename "$f") ]]; then place "$f" "$repo/.local/$(basename "$f")" 600; fi
    done
    f="$stopped/repo-local/Start Transcriber.command"
    if [[ -f $f || -f $repo/.local/Start\ Transcriber.command ]]; then place "$f" "$repo/.local/Start Transcriber.command" 755; fi
    restore_enabled transcriber
    rm -f "$lock"
    say did "removed $lock"
    bootstrap transcriber
    health transcriber
    if [[ -d $stopped ]]; then mv "$stopped" "$dir/launchd/started-$(date +%Y%m%d-%H%M%S)"; fi # kept until health passed
    note "start: transcriber running"
    say PASS "ai.codecaine.transcriber.* running"
    ;;
rollback)
    # Restores the sotto services: after a verified data rollback, or when no migration step ever ran
    # (for example backup or plan refused after down).
    status=$(journal status)
    if [[ -n $status && $status != new ]]; then
        [[ $status == rolled-back && -n $(journal rolled_back_verified_at) ]] ||
            die "the archive journal is '$status': run migrate-sotto.py rollback --backup $dir first (it must pass)"
    fi
    ! ls "$agents"/ai.codecaine.transcriber.*.plist >/dev/null 2>&1 || die "transcriber plists are installed; run stop first"
    labels_gone transcriber || die "transcriber services are still running; run stop first"
    grep -q "'--sotto-data'" "$repo/scripts/archive/archive.py" ||
        die "$repo/scripts/archive/archive.py is the transcriber code; revert the rename in the main checkout first"
    for label in "${labels[@]}"; do
        place "$dir/launchd/LaunchAgents/ai.codecaine.sotto.$label.plist" "$agents/ai.codecaine.sotto.$label.plist" 600
    done
    for name in ai.codecaine.sotto.archive.plist ai.codecaine.sotto.server.plist; do
        if [[ -f $dir/launchd/repo-local/$name ]]; then place "$dir/launchd/repo-local/$name" "$repo/.local/$name" 600; fi
    done
    for name in "Start Transcriber.command" "Start Sotto.command"; do
        if [[ -f $dir/launchd/repo-local/$name ]]; then place "$dir/launchd/repo-local/$name" "$repo/.local/$name" 755; fi
    done
    restore_enabled sotto
    rm -f "$lock"
    bootstrap sotto
    health sotto
    note "rollback: sotto running"
    say PASS "ai.codecaine.sotto.* restored and running"
    ;;
*)
    sed -n '2,28p' "$0"
    exit 2
    ;;
esac
