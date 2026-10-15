#!/bin/bash
# Phase 2 of the sotto rename: move the repository folder .../utilities/sotto to .../utilities/transcriber.
# Run it from Terminal.app after Phase 1, with no agent sessions, editors, dev servers or shells inside the
# repository or any of its worktrees (including the external campaign worktree):
#
#   cd ~ && bash <repo>/scripts/archive/migrate-repo-folder.sh check                 read-only preflight
#   cd ~ && bash <repo>/scripts/archive/migrate-repo-folder.sh run                   drain, stop, move, repair, rewrite, start
#   cd ~ && bash <new repo>/scripts/archive/migrate-repo-folder.sh rollback --work DIR
#
# Services are drained and stopped by migrate-sotto-launchd.sh stop, which also moves their plists out of
# ~/Library/LaunchAgents, so a reboot mid-move starts nothing. Rollback inverse-rewrites the current files.
set -euo pipefail

OLD=/Users/Ford/workspace/codebases/codecaine/utilities/sotto
NEW=/Users/Ford/workspace/codebases/codecaine/utilities/transcriber
TRANSCRIPTS="$HOME/Transcripts"

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

# The script lives inside the folder it moves: run from a private copy with cwd outside the repository.
if [[ -z ${MIGRATE_REPO_REEXEC:-} && $command =~ ^(run|rollback)$ ]]; then
    if [[ -z $work ]]; then
        [[ $command == run ]] || die "rollback needs --work DIR from the run"
        work="$HOME/TranscriberMigration/repo-folder-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$work"
    cp "$0" "$work/migrate-repo-folder.sh"
    cd /
    MIGRATE_REPO_REEXEC=1 exec bash "$work/migrate-repo-folder.sh" "$command" --work "$work"
fi
cd /

worktrees() { # worktrees REPO: linked worktree paths (not the main one)
    git -C "$1" worktree list --porcelain | awk '/^worktree /{n++; if (n > 1) print substr($0, 10)}'
}

ptree() { # ptree PID...: the PIDs and all their descendants
    local p
    for p in "$@"; do
        printf '%s ' "$p"
        # shellcheck disable=SC2046
        ptree $(pgrep -P "$p" || true)
    done
}

inside() { # inside ROOT...: processes whose cwd or executable lies under any ROOT, minus the services' trees
    local skip=" $$ " label pid
    for label in server archive; do
        pid=$(launchctl print "gui/$(id -u)/ai.codecaine.transcriber.$label" 2>/dev/null | awk '$1 == "pid" {print $3}')
        # shellcheck disable=SC2046,SC2086
        [[ -z $pid ]] || skip+="$(ptree $pid)"
    done
    for kind in cwd txt; do
        lsof -nP -d "$kind" -Fpcn 2>/dev/null | ROOTS="$(printf '%s\034' "$@")" awk -v kind="$kind" -v skip="$skip" '
            BEGIN {n = split(ENVIRON["ROOTS"], r, "\034")}
            /^p/ {pid = substr($0, 2)}
            /^c/ {cmd = substr($0, 2)}
            /^n/ {path = substr($0, 2)
                  if (index(skip, " " pid " ")) next
                  for (i = 1; i <= n; i++) if (r[i] != "" && (path == r[i] || index(path, r[i] "/") == 1))
                      print "    pid " pid " (" cmd ") " kind " " path}'
    done | sort -u
}

files_to_rewrite() { # files_to_rewrite REPO WORK: every file that names the repository path
    local repo=$1 stopped="$2/launchd/stopped" f
    for f in "$stopped"/LaunchAgents/*.plist "$stopped"/repo-local/*.plist "$stopped/repo-local/Start Transcriber.command"; do
        [[ -f $f ]] && printf '%s\n' "$f"
    done
    printf '%s\n' "$repo/.local/archive-config.json" "$repo/.local/archive-cache/transcriber-state.json" \
        "$TRANSCRIPTS/installation.json"
}

rewrite() { # rewrite FROM TO WORK: swap paths with the helper in TO, then prove FROM is gone
    local from=$1 to=$2 list=()
    while IFS= read -r f; do list+=("$f"); done < <(files_to_rewrite "$to" "$3")
    python3 "$to/scripts/archive/rewrite-repo-paths.py" "$from" "$to" "${list[@]}"
    if grep -l -F "$from" "${list[@]}"; then die "the files above still name $from"; fi
    say ok "${#list[@]} files checked; none names $from"
}

repair() { # repair REPO TREES_FILE: point every listed worktree at REPO/.git
    local repo=$1 trees=()
    while IFS= read -r wt; do
        if [[ -d $wt ]]; then trees+=("$wt"); else say warn "worktree $wt is missing; skipped"; fi
    done <"$2"
    [[ ${#trees[@]} -eq 0 ]] || git -C "$repo" worktree repair "${trees[@]}"
    for wt in ${trees[@]+"${trees[@]}"}; do
        [[ $(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) == "$repo/.git" ]] ||
            die "worktree $wt does not point at $repo/.git"
    done
    say ok "repaired ${#trees[@]} worktrees to $repo"
}

relocate() { # relocate TREES_FILE FROM TO > NEW_TREES_FILE
    while IFS= read -r wt; do
        if [[ $wt == "$2"/* ]]; then printf '%s\n' "$3${wt#"$2"}"; else printf '%s\n' "$wt"; fi
    done <"$1"
}

require_quiet() { # require_quiet REPO: nothing runs inside the repository or any linked worktree
    local roots=("$1") busy wt
    while IFS= read -r wt; do
        if [[ $wt != "$1"/* ]]; then roots+=("$wt"); fi
    done < <(worktrees "$1")
    busy=$(inside "${roots[@]}")
    [[ -z $busy ]] || die "processes are using the repository or a worktree; close them and rerun:
$busy"
    say ok "no process has its cwd or executable in: ${roots[*]}"
}

preflight() {
    [[ -d $OLD && $(git -C "$OLD" rev-parse --show-toplevel) == "$OLD" ]] || die "$OLD is not the repository root"
    [[ ! -e $NEW ]] || die "$NEW already exists"
    for label in server archive app; do
        [[ -f $HOME/Library/LaunchAgents/ai.codecaine.transcriber.$label.plist ]] || die "Phase 1 is not done (ai.codecaine.transcriber.$label.plist)"
        [[ ! -e $HOME/Library/LaunchAgents/ai.codecaine.sotto.$label.plist ]] || die "Phase 1 is not done (ai.codecaine.sotto.$label.plist)"
    done
    [[ -f $OLD/.local/archive-cache/transcriber-state.json && ! -e $OLD/.local/archive-cache/sotto-state.json ]] ||
        die "Phase 1 is not done: worker state is not transcriber-state.json"
    grep -q "'--transcriber-data'" "$OLD/scripts/archive/archive.py" || die "the main checkout still runs the sotto code"
    require_quiet "$OLD"
    say info "linked worktrees:"
    worktrees "$OLD" | sed 's/^/    /'
}

follow_ups() {
    cat <<EOF
[todo] Not done by this script:
    1. T3 Code: point the project's workspaceRoot at $NEW.
    2. ~/.codex/config.toml: rename [projects."$OLD"] to [projects."$NEW"].
    3. $NEW/codecaine.docs.json: "name": "Sotto" -> "Transcriber", then commit.
    4. Claude Code history for the old path stays under ~/.claude/projects/; reopen sessions in $NEW.
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
    worktrees "$OLD" >"$work/worktrees.old"
    relocate "$work/worktrees.old" "$OLD" "$NEW" >"$work/worktrees.new"
    bash "$OLD/scripts/archive/migrate-sotto-launchd.sh" stop --dir "$work"
    require_quiet "$OLD"
    mv "$OLD" "$NEW"
    say did "moved $OLD -> $NEW"
    repair "$NEW" "$work/worktrees.new"
    rewrite "$OLD" "$NEW" "$work"
    bash "$NEW/scripts/archive/migrate-sotto-launchd.sh" start --dir "$work"
    say PASS "repository is now $NEW. Undo: cd ~ && bash $work/migrate-repo-folder.sh rollback --work $work"
    follow_ups
    ;;
rollback)
    [[ -f $work/worktrees.old ]] || die "--work must be the directory from a run"
    exec > >(tee -a "$work/rollback.log") 2>&1
    [[ -d $NEW && ! -e $OLD ]] || die "expected $NEW present and $OLD absent"
    [[ ! -e $work/launchd/stopped ]] || mv "$work/launchd/stopped" "$work/launchd/stopped-before-rollback-$(date +%s)"
    bash "$NEW/scripts/archive/migrate-sotto-launchd.sh" stop --dir "$work"
    require_quiet "$NEW"
    mv "$NEW" "$OLD"
    say did "moved $NEW -> $OLD"
    repair "$OLD" "$work/worktrees.old"
    rewrite "$NEW" "$OLD" "$work"
    bash "$OLD/scripts/archive/migrate-sotto-launchd.sh" start --dir "$work"
    say PASS "repository is back at $OLD"
    ;;
*)
    sed -n '2,12p' "$0"
    exit 2
    ;;
esac
