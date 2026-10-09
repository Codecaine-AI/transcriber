# Transcriber

Transcriber is Codecaine's build of this project. It follows the upstream source and installs under its own fixed name, so an upstream rename never changes what macOS sees.

| What                  | Value                                       |
| --------------------- | ------------------------------------------- |
| Installed app         | `/Applications/Transcriber.app`             |
| Bundle identifier     | `ai.codecaine.transcriber`                  |
| Client settings       | `~/Library/Application Support/Transcriber` |
| Keychain service      | `ai.codecaine.transcriber.server`           |
| Signing configuration | `~/.config/transcriber/signing.json`        |

macOS ties Microphone, Accessibility, and Input Monitoring grants to the bundle identifier and the signing certificate. Both stay the same across rebuilds and upstream syncs, so the grants persist.

## How the name is applied

`scripts/install-local.py` runs upstream's `scripts/build-app.sh` unchanged. It then copies the result to `build/Transcriber.app`, rewrites the name and identifier in the copy's `Info.plist`, and signs the copy with the pinned local certificate. The app reads its name and identifier from its own bundle (`V07Build.swift`), so the settings directory and Keychain service follow the bundle.

With `--dev`, the same steps turn upstream's development build into `build/Transcriber Dev.app` (`ai.codecaine.transcriber.dev`). Its permissions, settings, and Keychain entries stay apart from the installed app.

Upstream's source tree, module names, `README.md`, and build scripts keep upstream's names. That keeps syncs free of rename conflicts. A few fixed labels inside the app window still show upstream's name.

## Commands

```sh
python3 scripts/setup-local-signing.py        # Once per Mac: create the signing certificate
./scripts/rebuild-local.sh --build-only       # Build and sign build/Transcriber.app
./scripts/rebuild-local.sh                    # Build, back up the installed app, replace it, reopen it
./scripts/rebuild-local.sh --dev              # Build and sign build/Transcriber Dev.app for testing
```

## Test with Transcriber Dev

Where upstream's `CLAUDE.md` and `AGENTS.md` say to verify in V07 Dev, verify in Transcriber Dev against an isolated source server instead. Start the server in its own terminal, then open the app with its own client directory:

```sh
bun run dev --port 8393 \
  --speech-model "$PWD/.local/models/ggml-large-v3-turbo.bin" \
  --proof-model "$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit"

open --env "V07_CLIENT_DATA_DIR=$PWD/.local/dev-client" \
  --env "V07_SERVER_URL=http://127.0.0.1:8393" "build/Transcriber Dev.app"
```

Enter the token from `.local/dev-server/token` once under **This Mac**. Transcriber Dev keeps it in the Keychain service `ai.codecaine.transcriber.dev.server`, under the account `<client data dir>|<server address>`.

## Fork differences

[Product Direction](docs/00-foundation/10-product-direction/doc.json) lists every difference from upstream and what to keep when merging. Behavior is described in [Architecture](docs/10-system-design/10-architecture/doc.json).

Project documentation lives in the [Docs corpus](docs/00-foundation/doc.json); start with [Current Status](docs/00-foundation/20-current-status/doc.json). The transcript archive is described in [scripts/archive/README.md](scripts/archive/README.md).
