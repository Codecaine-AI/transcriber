#!/bin/bash
# Phase 2 of the sotto rename: move the repository folder .../utilities/sotto to .../utilities/transcriber.
# Run it from Terminal.app after Phase 1, with no agent sessions, editors, dev servers or shells inside the
# repository or any of its worktrees (including the external campaign worktree):
#
#   cd ~ && bash <repo>/scripts/archive/migrate-repo-folder.sh check                 read-only preflight
#   cd ~ && bash <repo>/scripts/archive/migrate-repo-folder.sh run                   drain, stop, move, repair, rewrite, start
#   cd ~ && bash DIR/migrate-repo-folder.sh resume --work DIR      after a failure past the move: finish it
#   cd ~ && bash DIR/migrate-repo-folder.sh rollback --work DIR    undo (also after a failure)
#
# Services are drained and stopped by migrate-sotto-launchd.sh stop, which also moves their plists out of
# ~/Library/LaunchAgents, so a reboot mid-move starts nothing. Rollback inverse-rewrites the current files.
set -euo pipefail

OLD=/Users/Ford/workspace/codebases/codecaine/utilities/sotto
NEW=/Users/Ford/workspace/codebases/codecaine/utilities/transcriber
TRANSCRIPTS=${MIGRATE_TRANSCRIPTS:-$HOME/Transcripts}
AGENTS=${MIGRATE_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
if [[ -n ${MIGRATE_PHASE2_OLD:-}${MIGRATE_PHASE2_NEW:-} ]]; then # scratch rehearsals only
    [[ ${MIGRATE_PHASE2_OLD:-} == /private/tmp/* && ${MIGRATE_PHASE2_NEW:-} == /private/tmp/* ]] ||
        { printf '[FAIL] scratch folder overrides must both be under /private/tmp\n' >&2; exit 2; }
    OLD=$MIGRATE_PHASE2_OLD NEW=$MIGRATE_PHASE2_NEW
    printf '[scratch] OLD=%s NEW=%s agents=%s transcripts=%s\n' "$OLD" "$NEW" "$AGENTS" "$TRANSCRIPTS"
fi

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
if [[ -z ${MIGRATE_REPO_REEXEC:-} && $command =~ ^(run|resume|rollback)$ ]]; then
    if [[ -z $work ]]; then
        [[ $command == run ]] || die "$command needs --work DIR from the run"
        work="$HOME/TranscriberMigration/repo-folder-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$work"
    [[ $0 -ef $work/migrate-repo-folder.sh ]] || cp "$0" "$work/migrate-repo-folder.sh"
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
    local listing
    for kind in cwd txt; do
        # lsof exits 1 when it could not inspect some process; an empty listing means the check itself failed.
        listing=$(lsof -nP -d "$kind" -Fpcn 2>/dev/null) || true
        [[ -n $listing || -n ${MIGRATE_PHASE2_OLD:-} ]] || { printf '    lsof listed no processes; cannot prove the repository is unused\n'; continue; }
        printf '%s\n' "$listing" | ROOTS="$(printf '%s\034' "$@")" awk -v kind="$kind" -v skip="$skip" '
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
    # ~/Transcripts/installation.json is left alone: its source_repository is a historical path, not this repo.
    printf '%s\n' "$repo/.local/archive-config.json" "$repo/.local/archive-cache/transcriber-state.json"
}

rewrite() { # rewrite FROM TO WORK: swap paths with the helper in TO, then prove FROM is gone
    local from=$1 to=$2 list=()
    while IFS= read -r f; do list+=("$f"); done < <(files_to_rewrite "$to" "$3")
    local keep
    keep=$(mktemp -d "$3/before-rewrite-$(date +%Y%m%d-%H%M%S)-XXXXXX") # never reused, so no copy is overwritten
    for f in "${list[@]}"; do
        [[ -f $f ]] || die "missing $f"
        mkdir -p "$keep$(dirname "$f")"
        cp -p "$f" "$keep$f"
    done
    say ok "copied ${#list[@]} files to $keep before rewriting"
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
        [[ -f $AGENTS/ai.codecaine.transcriber.$label.plist ]] || die "Phase 1 is not done (ai.codecaine.transcriber.$label.plist)"
        [[ ! -e $AGENTS/ai.codecaine.sotto.$label.plist ]] || die "Phase 1 is not done (ai.codecaine.sotto.$label.plist)"
    done
    [[ -f $OLD/.local/archive-cache/transcriber-state.json && ! -e $OLD/.local/archive-cache/sotto-state.json ]] ||
        die "Phase 1 is not done: worker state is not transcriber-state.json"
    grep -q "'--transcriber-data'" "$OLD/scripts/archive/archive.py" || die "the main checkout still runs the sotto code"
    require_quiet "$OLD"
    say info "linked worktrees:"
    worktrees "$OLD" | sed 's/^/    /'
}

child=""
launchd() { # launchd ROOT ARGS...: run the launchd tool as a child we can pass a TERM on to
    bash "$1/scripts/archive/migrate-sotto-launchd.sh" "${@:2}" &
    child=$!
    wait "$child"
}

forward() { # forward CODE: on Ctrl-C or kill, stop the child (a background child ignores Ctrl-C), then report
    [[ -z $child ]] || kill -TERM "$child" 2>/dev/null || true
    [[ -z $child ]] || wait "$child" 2>/dev/null || true
    exit "$1"
}

transcriber_active() { # any transcriber label loaded, or any transcriber plist installed
    local label
    for label in server archive app; do
        if launchctl print "gui/$(id -u)/ai.codecaine.transcriber.$label" >/dev/null 2>&1; then return 0; fi
        if [[ -f $AGENTS/ai.codecaine.transcriber.$label.plist ]]; then return 0; fi
    done
    return 1
}

plists_name() { # which folder the stashed plists point at: OLD, NEW or unknown
    local f
    for f in "$work"/launchd/stopped/LaunchAgents/*.plist; do
        [[ -f $f ]] || continue
        if grep -q -F "$NEW/" "$f"; then echo NEW; return; fi
        if grep -q -F "$OLD/" "$f"; then echo OLD; return; fi
    done
    echo unknown
}

recovery() { # EXIT trap on failure: say exactly where things stand and how to continue
    local at named
    at=$([[ -d $NEW && ! -e $OLD ]] && echo NEW || ([[ -d $OLD && ! -e $NEW ]] && echo OLD || echo unknown))
    named=$(plists_name)
    printf '\n[RECOVER] Phase 2 stopped part-way. Folder: %s. Stashed plists point at: %s.\n' \
        "$([[ $at == NEW ]] && echo "$NEW" || ([[ $at == OLD ]] && echo "$OLD" || echo unclear))" "$named"
    if transcriber_active; then
        printf '  Transcriber services are installed or running; nothing is stranded.\n'
    elif [[ $at == NEW && $named != OLD ]]; then
        printf '  Finish (repair, rewrite, start):  cd ~ && bash %s/migrate-repo-folder.sh resume --work %s\n' "$work" "$work"
    elif [[ $at == NEW ]]; then
        printf '  Finish (the paths are not rewritten yet):  cd ~ && bash %s/migrate-repo-folder.sh resume --work %s\n' "$work" "$work"
    elif [[ $at == OLD && $named == OLD ]]; then
        printf '  Restart as before:  bash %s/scripts/archive/migrate-sotto-launchd.sh start --dir %s\n' "$OLD" "$work"
    elif [[ $at == OLD ]]; then
        printf '  The folder is back but the paths still name %s; finish the undo with the rollback below.\n' "$NEW"
    fi
    printf '  Undo everything (safe to rerun):  cd ~ && bash %s/migrate-repo-folder.sh rollback --work %s\n' "$work" "$work"
}

finish() { # after the move: each step is safe to rerun
    repair "$NEW" "$work/worktrees.new"
    rewrite "$OLD" "$NEW" "$work"
    launchd "$NEW" start --dir "$work"
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
    exec > >(tee -i -a "$work/run.log") 2>&1
    trap 'status=$?; [[ $status -eq 0 ]] || recovery' EXIT
    trap 'forward 130' INT
    trap 'forward 143' TERM
    say info "work directory: $work"
    preflight
    worktrees "$OLD" >"$work/worktrees.old"
    relocate "$work/worktrees.old" "$OLD" "$NEW" >"$work/worktrees.new"
    launchd "$OLD" stop --dir "$work"
    require_quiet "$OLD"
    mv "$OLD" "$NEW"
    say did "moved $OLD -> $NEW"
    finish
    say PASS "repository is now $NEW. Undo: cd ~ && bash $work/migrate-repo-folder.sh rollback --work $work"
    follow_ups
    ;;
resume)
    [[ -f $work/worktrees.new && -d $NEW && ! -e $OLD ]] || die "resume needs the folder at $NEW and --work from the run"
    exec > >(tee -i -a "$work/resume.log") 2>&1
    trap 'status=$?; [[ $status -eq 0 ]] || recovery' EXIT
    trap 'forward 130' INT
    trap 'forward 143' TERM
    finish
    say PASS "repository is now $NEW"
    follow_ups
    ;;
rollback)
    [[ -f $work/worktrees.old ]] || die "--work must be the directory from a run"
    exec > >(tee -i -a "$work/rollback.log") 2>&1
    trap 'status=$?; [[ $status -eq 0 ]] || recovery' EXIT
    trap 'forward 130' INT
    trap 'forward 143' TERM
    # Every step is safe to rerun: stop treats stopped services as stopped, the move and the rewrite skip
    # what is already done.
    if [[ -d $NEW && ! -e $OLD ]]; then
        if transcriber_active; then launchd "$NEW" stop --dir "$work"; else say info "services already stopped"; fi
        require_quiet "$NEW"
        mv "$NEW" "$OLD"
        say did "moved $NEW -> $OLD"
    elif [[ -d $OLD && ! -e $NEW ]]; then
        # Interrupted after the move back: the stashed paths may still name NEW, so stop only what is running.
        if transcriber_active; then launchd "$OLD" stop --dir "$work"; else say info "services already stopped"; fi
        say info "$OLD already in place"
    else
        die "expected exactly one of $OLD and $NEW"
    fi
    repair "$OLD" "$work/worktrees.old"
    rewrite "$NEW" "$OLD" "$work"
    launchd "$OLD" start --dir "$work"
    say PASS "repository is back at $OLD"
    ;;
*)
    sed -n '2,14p' "$0"
    exit 2
    ;;
esac
