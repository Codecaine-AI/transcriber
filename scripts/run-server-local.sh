#!/bin/bash
# Start the packaged server for the installed Transcriber app. Executables are
# found by role (transcriber-server, helpers/transcriber-engine and
# helpers/transcriber-text-engine from ./scripts/build-server.sh). Explicit
# arguments take precedence over the server's own TRANSCRIBER_* variables, so
# TRANSCRIBER_SPEECH_MODEL and TRANSCRIBER_TEXT_MODEL are resolved here once.
set -euo pipefail
shopt -s nullglob

project_dir=$(cd "$(dirname "$0")/.." && pwd)
package="$project_dir/build/server"

one() {
    local role=$1
    shift
    if [[ $# -ne 1 || ! -x "$1" ]]; then
        printf 'Expected one %s in %s. Run ./scripts/build-server.sh.\n' "$role" "$package" >&2
        exit 1
    fi
    printf '%s\n' "$1"
}

speech_helpers=()
for helper in "$package"/helpers/*-engine; do
    [[ "$helper" == *-text-engine ]] || speech_helpers+=("$helper")
done
server=$(one server "$package"/*-server)
text_helper=$(one 'text helper' "$package"/helpers/*-text-engine)
speech_helper=$(one 'speech helper' "${speech_helpers[@]}")

exec "$server" --host 127.0.0.1 --port 8391 --data-dir "$project_dir/.local/server" \
    --speech-helper "$speech_helper" \
    --speech-model "${TRANSCRIBER_SPEECH_MODEL:-$project_dir/.local/models/ggml-large-v3-turbo.bin}" \
    --vad-model "$package/resources/silero-vad.bin" \
    --proof-helper "$text_helper" \
    --proof-model "${TRANSCRIBER_TEXT_MODEL:-$project_dir/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit}"
