# Transcriber

Transcriber is Codecaine's fork of [davis7dotsh/inlay](https://github.com/davis7dotsh/inlay). The source is named Transcriber end to end: Swift targets and modules, the app bundle, the server and helper binaries (`transcriber-server`, `transcriber-engine`, `transcriber-text-engine`), and the `TRANSCRIBER_*` environment variables.

| What                  | Value                                       |
| --------------------- | ------------------------------------------- |
| Installed app         | `/Applications/Transcriber.app`             |
| Bundle identifier     | `ai.codecaine.transcriber`                  |
| Client settings       | `~/Library/Application Support/Transcriber` |
| Keychain service      | `ai.codecaine.transcriber.server`           |
| Signing configuration | `~/.config/transcriber/signing.json`        |

macOS ties Microphone, Accessibility, and Input Monitoring grants to the bundle identifier and the signing certificate. Both stay the same across rebuilds, so the grants persist.

## Upstream policy

Upstream is mined selectively. Specific features are hand-ported and adapted to Transcriber; upstream is never merged wholesale. Each port is listed under Fork Differences From Upstream in [Product Direction](docs/00-foundation/10-product-direction/doc.json).

## How the app is built and signed

`Resources/Info.plist` and `Resources/Info-Dev.plist` carry the app's name and identifier. `scripts/install-local.py` builds the bundle with `scripts/build-app.sh`, checks that its `CFBundleName`, `CFBundleIdentifier`, and `CFBundleExecutable` match the expected Transcriber values, and signs it with the pinned local certificate. The app reads its name and identifier from its own bundle (`TranscriberBuild.swift`), so the settings directory and Keychain service follow the bundle.

With `--dev`, the same steps produce `build/Transcriber Dev.app` (`ai.codecaine.transcriber.dev`). Its permissions, settings, and Keychain entries stay apart from the installed app.

## Archive and service names

The transcript archive and its services use the Transcriber name too: the launchd labels `ai.codecaine.transcriber.{server,archive,app}`, the archive source id `transcriber` (`records/transcriber/`), the worker state file `transcriber-state.json`, and the archive's `--transcriber-data` option. `scripts/archive/migrate-sotto.py` and `scripts/archive/migrate-sotto-launchd.sh` moved existing data off the old `sotto` names.

The repository folder is the last place the old `sotto` name remains. `scripts/archive/migrate-repo-folder.sh` renames it; run it from Terminal.app with no agent sessions inside the repository.

## Commands

```sh
python3 scripts/setup-local-signing.py        # Once per Mac: create the signing certificate
./scripts/rebuild-local.sh --build-only       # Build and sign build/Transcriber.app
./scripts/rebuild-local.sh                    # Build, back up the installed app, replace it, reopen it
./scripts/rebuild-local.sh --dev              # Build and sign build/Transcriber Dev.app for testing
```

## Test with Transcriber Dev

Verify behavior in Transcriber Dev against an isolated source server. Start the server in its own terminal, then open the app with its own client directory:

```sh
bun run dev --port 8393 \
  --speech-model "$PWD/.local/models/ggml-large-v3-turbo.bin" \
  --proof-model "$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit"

open --env "TRANSCRIBER_CLIENT_DATA_DIR=$PWD/.local/dev-client" \
  --env "TRANSCRIBER_SERVER_URL=http://127.0.0.1:8393" "build/Transcriber Dev.app"
```

Enter the token from `.local/dev-server/token` once under **This Mac**. Transcriber Dev keeps it in the Keychain service `ai.codecaine.transcriber.dev.server`, under the account `<client data dir>|<server address>`.

## Fork differences

[Product Direction](docs/00-foundation/10-product-direction/doc.json) lists every difference from upstream, including each hand-ported feature. Behavior is described in [Architecture](docs/10-system-design/10-architecture/doc.json).

Project documentation lives in the [Docs corpus](docs/00-foundation/doc.json); start with [Current Status](docs/00-foundation/20-current-status/doc.json). The transcript archive is described in [scripts/archive/README.md](scripts/archive/README.md).
