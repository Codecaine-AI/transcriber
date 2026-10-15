#!/bin/bash
# Phase 2 of the sotto rename: move the repository folder .../utilities/sotto to .../utilities/transcriber.
# Run it from Terminal.app after Phase 1 (migrate-sotto.py + migrate-sotto-launchd.sh up), with no agent
# sessions, editors, dev servers or shells inside the repository or its worktrees:
#
#   cd ~ && bash <repo>/scripts/archive/migrate-repo-folder.sh check              read-only preflight
#   cd ~ && bash <repo>/scripts/archive/migrate-repo-folder.sh run                stop, move, repair, rewrite, start
#   cd ~ && bash <new repo>/scripts/archive/migrate-repo-folder.sh rollback --work DIR
#
# `run` keeps a copy of every file it rewrites, the worktree list and a log in ~/TranscriberMigration/repo-folder-*.
set -euo pipefail

OLD=/Users/Ford/workspace/codebases/codecaine/utilities/sotto
NEW=/Users/Ford/workspace/codebases/codecaine/utilities/transcriber
AGENTS="$HOME/Library/LaunchAgents"
TRANSCRIPTS="$HOME/Transcripts"
DOMAIN="gui/$(id -u)"
SERVICES=(server archive) # the app label only runs `open /Applications/Transcriber.app`; it has no repo path

die() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 2
}
say() { printf '[%s] %s\n' "$1" "$2"; }

command=${1:-}
[[ $# -gt 0 ]] && shift
work=""
while [[ $# -gt 0 ]]; do
    case $1 in
    --work)
        [[ $# -ge 2 ]] || die "--work needs a directory"
        work=$2
        shift 2
        ;;
    *) die "unknown argument: $1" ;;
    esac
done

# The script itself lives inside the folder it moves: re-run from a private copy, with cwd outside the repo.
if [[ -z ${MIGRATE_REPO_REEXEC:-} && $command =~ ^(run|rollback)$ ]]; then
    if [[ -z $work ]]; then
        work="$HOME/TranscriberMigration/repo-folder-$(date +%Y%m%d-%H%M%S)"
        [[ $command == run ]] || die "rollback needs --work DIR from the run"
    fi
    mkdir -p "$work"
    cp "$0" "$work/migrate-repo-folder.sh"
    cd /
    MIGRATE_REPO_REEXEC=1 exec bash "$work/migrate-repo-folder.sh" "$command" --work "$work"
fi
cd /

loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }
service_pid() { launchctl print "$DOMAIN/$1" 2>/dev/null | awk '$1 == "pid" {print $3}'; }
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | tr '\n' ' ' || true; }

ptree() { # ptree PID...: the PIDs and all their descendants
    local p
    for p in "$@"; do
        printf '%s ' "$p"
        # shellcheck disable=SC2046
        ptree $(pgrep -P "$p" || true)
    done
}

inside() { # inside ROOT: processes whose cwd or executable/mapped text lies under ROOT, minus our services' process trees
    local root=$1 skip=" $$ " label
    for label in "${SERVICES[@]}"; do
        # shellcheck disable=SC2046
        skip+="$(ptree $(service_pid "ai.codecaine.transcriber.$label"))"
    done
    for kind in cwd txt; do
        lsof -nP -d "$kind" -Fpcn 2>/dev/null | awk -v root="$root" -v kind="$kind" -v skip="$skip" '
            /^p/ {pid = substr($0, 2)}
            /^c/ {cmd = substr($0, 2)}
            /^n/ {n = substr($0, 2)
                  if ((n == root || index(n, root "/") == 1) && index(skip, " " pid " ") == 0)
                      print "    pid " pid " (" cmd ") " kind " " n}'
    done | sort -u
}

worktrees() { # worktrees REPO: linked worktree paths (not the main one), one per line
    git -C "$1" worktree list --porcelain | awk '/^worktree /{n++; if (n > 1) print substr($0, 10)}'
}

stop_services() {
    for label in "${SERVICES[@]}"; do
        if loaded "ai.codecaine.transcriber.$label"; then
            launchctl bootout "$DOMAIN/ai.codecaine.transcriber.$label"
            say did "bootout ai.codecaine.transcriber.$label"
        fi
    done
    for _ in $(seq 100); do
        local busy=0
        for label in "${SERVICES[@]}"; do
            if loaded "ai.codecaine.transcriber.$label"; then busy=1; fi
        done
        for port in 8391 8392; do
            if [[ -n $(listeners "$port") ]]; then busy=1; fi
        done
        if [[ $busy -eq 0 ]]; then break; fi
        sleep 0.2
    done
    for port in 8391 8392; do
        [[ -z $(listeners "$port") ]] || die "port $port still in use by: $(listeners "$port")"
    done
    say ok "server and archive services stopped; ports 8391 and 8392 closed"
}

start_services() { # start_services EXPECTED_RECORDS
    for label in "${SERVICES[@]}"; do
        launchctl bootstrap "$DOMAIN" "$AGENTS/ai.codecaine.transcriber.$label.plist"
        say did "bootstrap ai.codecaine.transcriber.$label"
    done
    for _ in $(seq 120); do
        curl -fsS -m 2 -o /dev/null http://127.0.0.1:8391/v1/health 2>/dev/null && break
        sleep 1
    done
    curl -fsS -m 2 -o /dev/null http://127.0.0.1:8391/v1/health || die "server health on 8391 did not answer"
    say ok "server answers on http://127.0.0.1:8391/v1/health"
    local summary=""
    for _ in $(seq 120); do
        summary=$(curl -fsS -m 5 http://127.0.0.1:8392/api/summary 2>/dev/null || true)
        if [[ -n $summary ]] && python3 - "$summary" "$1" <<'PY'; then break; fi
import json, sys
d, expected = json.loads(sys.argv[1]), int(sys.argv[2])
counts = {s['source']: s['records'] for s in d['sources']}
sys.exit(0 if counts.get('transcriber', 0) >= expected and d.get('last_transcriber_sync') and not d['error'] else 1)
PY
        summary=""
        sleep 1
    done
    [[ -n $summary ]] || die "archive viewer on 8392 did not report a clean transcriber sync"
    say ok "archive viewer on 8392: $summary"
}

# Every file whose content names the repository path. Paths are relative to the repo when under it.
files_to_rewrite() {
    local repo=$1 label
    for label in server archive app; do printf '%s\n' "$AGENTS/ai.codecaine.transcriber.$label.plist"; done
    for label in archive server; do printf '%s\n' "$repo/.local/ai.codecaine.transcriber.$label.plist"; done
    printf '%s\n' "$repo/.local/Start Transcriber.command" "$repo/.local/archive-config.json" \
        "$repo/.local/archive-cache/transcriber-state.json" "$TRANSCRIPTS/installation.json"
}

rewrite() { # rewrite FROM TO: swap the repository path in every file from files_to_rewrite
    local from=$1 to=$2
    files_to_rewrite "$to" | python3 - "$from" "$to" <<'PY'
import difflib, json, os, plistlib, sys
from pathlib import Path
old, new = sys.argv[1], sys.argv[2]
sys.path.insert(0, f'{new}/scripts/archive')
from archive import atomic, encode

def swap(value):
    if isinstance(value, str):
        return new + value[len(old):] if value == old or value.startswith(old + '/') else value
    if isinstance(value, list):
        return [swap(v) for v in value]
    if isinstance(value, dict):
        return {swap(k) if isinstance(k, str) else k: swap(v) for k, v in value.items()}
    return value

for line in sys.stdin.read().splitlines():
    p = Path(line)
    if not p.is_file():
        print(f'    skip (absent): {p}')
        continue
    before = p.read_bytes()
    mode = p.stat().st_mode & 0o777
    if p.suffix == '.plist':
        after = plistlib.dumps(swap(plistlib.loads(before)), fmt=plistlib.FMT_XML)
    elif p.name == 'transcriber-state.json':
        data = json.loads(before)
        moved = swap(data)
        assert len(moved) == len(data), 'state keys collided'
        assert all(k.startswith(new + '/.local/server/generations/') for k in moved), 'state key outside the repo'
        after = encode(moved)
    elif p.name == 'archive-config.json':
        after = encode(swap(json.loads(before)))
    elif p.name == 'installation.json':
        data = json.loads(before)
        data['source_repository'] = new
        after = (json.dumps(data, indent=2, ensure_ascii=False) + ('\n' if before.endswith(b'\n') else '')).encode()
    else:  # Start Transcriber.command
        text = before.decode()
        assert text.count(f'transcriber_root={old}\n') == 1 and text.count(old) == 1, 'unexpected launcher'
        after = text.replace(f'transcriber_root={old}\n', f'transcriber_root={new}\n').encode()
    assert old.encode() + b'/' not in after and not after.rstrip().endswith(old.encode()), f'{p} still names {old}'
    if after == before:
        print(f'    unchanged: {p}')
        continue
    atomic(p, after)
    os.chmod(p, mode)
    print(f'    rewrote {p}')
    if p.name != 'transcriber-state.json':
        for d in difflib.unified_diff(before.decode().splitlines(), after.decode().splitlines(), lineterm='', n=0):
            if d[:1] in '+-' and d[:3] not in ('+++', '---'):
                print('      ' + d)
    else:
        print(f'      {len(json.loads(after))} keys moved to {new}/.local/server/generations/')
PY
    local f
    for f in "$AGENTS"/ai.codecaine.transcriber.*.plist "$to"/.local/ai.codecaine.transcriber.*.plist; do
        plutil -lint "$f" >/dev/null || die "plutil -lint failed: $f"
    done
    say ok "rewrote repository paths $from -> $to; plists lint clean"
}

preflight() {
    [[ -d $OLD && $(git -C "$OLD" rev-parse --show-toplevel) == "$OLD" ]] || die "$OLD is not the repository root"
    [[ ! -e $NEW ]] || die "$NEW already exists"
    for label in server archive app; do
        [[ -f $AGENTS/ai.codecaine.transcriber.$label.plist ]] || die "Phase 1 is not done: missing ai.codecaine.transcriber.$label.plist"
        [[ ! -e $AGENTS/ai.codecaine.sotto.$label.plist ]] || die "Phase 1 is not done: ai.codecaine.sotto.$label.plist still installed"
    done
    [[ -f $OLD/.local/archive-cache/transcriber-state.json && ! -e $OLD/.local/archive-cache/sotto-state.json ]] ||
        die "Phase 1 is not done: worker state is still sotto-state.json"
    grep -q "'--transcriber-data'" "$OLD/scripts/archive/archive.py" || die "the main checkout still runs the sotto archive code"
    local busy
    busy=$(inside "$OLD")
    [[ -z $busy ]] || die "processes are using the repository; close them and rerun:
$busy"
    say ok "no process has its cwd or executable inside $OLD (services excluded)"
    say info "linked worktrees to repair:"
    worktrees "$OLD" | sed 's/^/    /'
    say info "files whose repository path will be rewritten:"
    files_to_rewrite "$OLD" | sed 's/^/    /'
}

follow_ups() {
    cat <<EOF
[todo] Not done by this script:
    1. T3 Code: point the project's workspaceRoot at $NEW (T3 project settings, or t3_project_update).
    2. ~/.codex/config.toml: rename the trust entry [projects."$OLD"] to [projects."$NEW"].
    3. $NEW/codecaine.docs.json: change "name": "Sotto" to "Transcriber" and commit it.
    4. Claude Code keeps per-folder history under ~/.claude/projects/; sessions for the old path stay under the old name.
    5. Open editors, terminals and Finder favourites that pointed at the old folder need reopening.
EOF
}

case $command in
check)
    preflight
    say PASS "preflight passed; nothing changed"
    ;;
run)
    exec > >(tee -a "$work/run.log") 2>&1
    say info "work directory: $work"
    preflight
    expected=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$OLD/.local/archive-cache/transcriber-state.json")
    git -C "$OLD" worktree list --porcelain >"$work/worktrees.porcelain"
    new_trees=()
    while IFS= read -r wt; do
        if [[ ! -d $wt ]]; then
            say warn "worktree $wt is missing; leaving it for git worktree prune"
        elif [[ $wt == "$OLD"/* ]]; then
            new_trees+=("$NEW${wt#"$OLD"}")
        else
            new_trees+=("$wt")
        fi
    done < <(worktrees "$OLD")
    printf '%s\n' ${new_trees[@]+"${new_trees[@]}"} >"$work/worktrees.new"
    mkdir -p "$work/files"
    files_to_rewrite "$OLD" | while IFS= read -r f; do
        if [[ -f $f ]]; then
            mkdir -p "$work/files$(dirname "$f")"
            cp -p "$f" "$work/files$f"
        fi
    done
    say ok "backed up $(find "$work/files" -type f | wc -l | tr -d ' ') files to $work/files"

    stop_services
    busy=$(inside "$OLD")
    [[ -z $busy ]] || die "processes appeared inside the repository; services are stopped. Close them, then run: launchctl bootstrap $DOMAIN $AGENTS/ai.codecaine.transcriber.{server,archive}.plist
$busy"
    mv "$OLD" "$NEW"
    say did "moved $OLD -> $NEW"
    if [[ ${#new_trees[@]} -gt 0 ]]; then
        git -C "$NEW" worktree repair "${new_trees[@]}"
    fi
    for wt in ${new_trees[@]+"${new_trees[@]}"}; do
        [[ $(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) == "$NEW/.git" ]] ||
            die "worktree $wt does not point at $NEW/.git after repair; see rollback"
    done
    ! git -C "$NEW" worktree list --porcelain | grep -q '^prunable' || say warn "git reports prunable worktrees: git -C $NEW worktree list"
    say ok "repaired ${#new_trees[@]} worktrees"
    rewrite "$OLD" "$NEW"
    start_services "$expected"
    after=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$NEW/.local/archive-cache/transcriber-state.json")
    [[ $after -ge $expected ]] || die "worker state shrank from $expected to $after"
    say PASS "repository is now $NEW; rollback with: bash $work/migrate-repo-folder.sh rollback --work $work"
    follow_ups
    ;;
rollback)
    [[ -f $work/worktrees.porcelain && -d $work/files ]] || die "--work must be the directory from a run"
    exec > >(tee -a "$work/rollback.log") 2>&1
    stop_services
    if [[ -d $NEW && ! -e $OLD ]]; then
        busy=$(inside "$NEW")
        [[ -z $busy ]] || die "processes are using $NEW:
$busy"
        mv "$NEW" "$OLD"
        say did "moved $NEW -> $OLD"
    fi
    [[ -d $OLD && ! -e $NEW ]] || die "expected $OLD present and $NEW absent"
    present=()
    while IFS= read -r wt; do
        if [[ -d $wt ]]; then present+=("$wt"); fi
    done < <(awk '/^worktree /{n++; if (n > 1) print substr($0, 10)}' "$work/worktrees.porcelain")
    if [[ ${#present[@]} -gt 0 ]]; then git -C "$OLD" worktree repair "${present[@]}"; fi
    say ok "repaired ${#present[@]} worktrees back to $OLD"
    (cd "$work/files" && find . -type f) | while IFS= read -r rel; do
        cp -p "$work/files/${rel#./}" "/${rel#./}"
        say did "restored /${rel#./}"
    done
    for label in "${SERVICES[@]}"; do
        launchctl bootstrap "$DOMAIN" "$AGENTS/ai.codecaine.transcriber.$label.plist"
        say did "bootstrap ai.codecaine.transcriber.$label"
    done
    say PASS "repository is back at $OLD; check http://127.0.0.1:8392"
    ;;
*)
    sed -n '2,10p' "$0"
    exit 2
    ;;
esac
