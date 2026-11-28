# Transcriber

Docs: hub project transcriber-ce2a47c6 (docs/). Start at docs/40-guides/50-source-development.
No automated tests of the app, the server or the Hub. Verify with computer use in Transcriber Dev. The one test file covers the transcript archive (see "Test commands").
After TS edits: `bun run fmt`, then `bun run check`, `bun run lint`, `bun run fmt:check`.
Fix a failing check. Never weaken a check or add a blanket lint suppression. Spreading strings is allowed on purpose (Unicode scalar iteration).
Never edit vendor/whisper.cpp or vendor/llama.cpp.

## Test commands

Run every command from the repo root. Install with `bun install` at the root (the `Server` workspace), then `bun install` in `Hub/` and in `Client/hub-sync/`. The archive tests need Python 3.12 or later and no packages.

**Tier 1, every change:**

- TypeScript in `Server/`: `bun run fmt`, then `bun run check`, `bun run lint` and `bun run fmt:check`.
- `Hub/` or `Client/hub-sync/`: `bun run --cwd Hub typecheck` or `bun run --cwd Client/hub-sync typecheck`.
- `scripts/archive/`: `python3 -m unittest discover -s scripts/archive -v` (1 file, 6 tests, under 1 s). One test from `scripts/archive`: `python3 -m unittest -v test_archive.ArchiveTests.<method>`.

**Tier 2, before a PR:** there is no changed-files gate. Diff base: `origin/main`. CI (`.github/workflows/server.yml`) runs `bun run fmt:check`, `bun run check` and `bun run lint` on Ubuntu, and `bun run generate:api --check` and `swift build --force-resolved-versions` on macOS 26. Run the Tier 1 commands of every touched area. The areas below say which checks own which code:

| Area                        | Owns                                                                                                           | Tests and checks                                                                                       |
| --------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `Server/`                   | The TypeScript transcription server and its OpenAPI contract                                                   | `bun run check` (typecheck and generated API bindings), `bun run lint`, `bun run fmt:check`. No tests. |
| `Sources/`, `Package.swift` | The macOS app and its Swift API bindings                                                                       | `swift build --force-resolved-versions` and `bun run generate:api --check` on macOS. No tests.         |
| `Hub/`, `Client/hub-sync/`  | The transcript hub on services-01 and the sync job that posts archive records to it                            | `bun run --cwd Hub typecheck`, `bun run --cwd Client/hub-sync typecheck`. No tests.                    |
| `scripts/archive/`          | The portable transcript archive: Wispr imports, Transcriber sync, integrity verify, search index, local viewer | `scripts/archive/test_archive.py`                                                                      |

Routing rules:

- A change in `scripts/archive/archive.py` or `viewer.py` runs the archive tests.
- A change in the archive record layout (`records/<source>/<id>/metadata.json`, `raw.txt`, `clean.txt`) also runs `bun run --cwd Client/hub-sync typecheck` and needs a check of `Client/hub-sync/src/archive.ts`, which reads that layout.
- A change in `Server/api/openapi.yaml` runs `bun run check` here and `bun run generate:api --check` on macOS.
- No other repo imports this code. services-app-gateway `caddy/sites/lascari.dev/transcripts.caddy` and `scripts/test-transcripts.sh` proxy the Hub viewer on `127.0.0.1:8798`. Check a change to the viewer's paths or methods against them.
- A change only in `docs/` or `*.md` runs no tests.

**Tier 3, before a big merge:** every command above, with the Swift build on macOS.

**macOS only:** `swift build --force-resolved-versions` and the full `bun run generate:api --check` need macOS and Xcode 26. They run on the MacBook and in the `swift` CI job.

**Keeper tests:** these are the only proof of a user flow. A prune must keep them, test by test. All are in `scripts/archive/test_archive.py`.

| Flow                                                                                                                  | Keeper                                                                         |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| A Wispr SQLite import keeps every column, large audio, null dates and the dictionary, and leaves the source unchanged | `ArchiveTests.test_large_audio_null_dates_all_fields_and_dictionary_survive`   |
| A Transcriber sync keeps each new metadata version and the audio once                                                 | `ArchiveTests.test_media_versions_and_transcriber_updates_are_retained`        |
| A WisprSync export import keeps the original metadata, and verify catches a corrupted artifact                        | `ArchiveTests.test_export_integrity_metadata_and_original_files_are_preserved` |
| A record id never escapes the record folder                                                                           | `ArchiveTests.test_identifiers_cannot_escape_record_directory`                 |
| The local viewer searches, pages, serves byte ranges and refuses foreign hosts and path traversal                     | `ViewerTests.test_search_pagination_media_ranges_and_local_access`             |

**Known failures on main:** `test_archive.ArchiveTests.test_failed_transcriber_copy_is_retried_and_cache_is_rebuildable` expects `sync_transcriber` to raise on a record with missing audio. `sync_transcriber` now logs the record, keeps syncing and retries it on the next pass, so no error is raised.

**Quarantine:** none. Each entry needs the test title, an owner and an expiry date.
