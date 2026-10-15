# Shared Transcript Archive

The archive is the permanent, portable home for historical Wispr records and new Transcriber recordings. The one-time migration reads the existing WisprSync export and read-only SQLite snapshots. After migration, only Transcriber is monitored. The worker copies new finished recordings every three seconds and retries failures. Deleting a source recording does not delete its archived copy.

## Structure

```text
<archive>/
  dataset.json
  migration.json
  verification.json
  records/
    wispr-flow/<source-id>/
      metadata.json
      raw.txt
      clean.txt
      source_versions/<sha256>.json
      artifacts/<sha256>.<extension>
    transcriber/<generation-id>/
      metadata.json
      raw.txt
      clean.txt
      source_versions/<sha256>.json
      artifacts/<sha256>.<extension>
  sources/
    wisprsync-export/<manifest-hash>/  # Original manifest, indexes, run reports
    wispr-flow/dictionary-<sha256>.json
```

Metadata distinguishes missing text from empty text, records the chosen clean-text variant, and retains all available transcript variants. Unknown dates remain null; invalid or missing source IDs receive stable safe identifiers and remain represented in original source metadata. Files are copied in 1 MiB chunks with SHA-256 verification; this is a transfer buffer, not a file-size limit. Competing source versions and attachments are retained by hash. The database used for search lives in the local cache, outside a cloud-synced archive, and can be rebuilt from the files.

The portable archive is separate from Transcriber's operational history. The server records raw.txt and clean.txt alongside each finished recording before publishing metadata. The archive worker then copies the complete metadata and audio. The Data page shows archive health and any copy failure. Closing the app does not stop the worker. The archive is intended for one writer on this Mac; sharing its folder does not make simultaneous writers safe.

The original upstream Wispr importer remains in source for compatibility, with its bounded HTTP contract. Our one-time migration does not use that importer or its 8 MiB limit. The Codecaine UI directs users to the full archive instead.

## Commands

Python 3.12 or later is required. Run from the repository root; replace the example paths.

```sh
python3 scripts/archive/archive.py --root /path/to/Transcripts --cache .local/archive-cache migrate \
  --wisprsync /path/to/wispr_sync --wispr-db /path/to/flow.sqlite \
  --backup /path/to/backup.sqlite
python3 scripts/archive/archive.py --root /path/to/Transcripts --cache .local/archive-cache verify
python3 scripts/archive/archive.py --root /path/to/Transcripts --cache .local/archive-cache serve \
  --transcriber-data .local/server
```

Use `--backup` repeatedly for additional complete backups. A failed migration leaves `migration.json` marked failed and can be retried; original sources are unchanged. Inspect verification before retiring the old exporter.

`python3 scripts/archive/install.py --root /path/to/Transcripts` configures the worker for the current login session and updates `.local/Start Transcriber.command`. It does not enable launch at login. That launcher starts both dictation and archive services. The Data page and browser viewer use `http://127.0.0.1:8392`.

Archives created before the Transcriber rename stored new recordings under the `sotto` source id. `migrate-sotto.py` (`plan`, `backup`, `migrate`, `verify`, `rollback`) moves them to `records/transcriber/` and updates the search index, worker state, and configuration. Backup and verify compare a complete typed inventory of the archive, and rollback is exact and only allowed while the migrated data is unchanged. `migrate-sotto-launchd.sh` (`down`, `up`, `stop`, `start`, `rollback`) drains the app, server and worker before swapping the `ai.codecaine.sotto.*` services for `ai.codecaine.transcriber.*`. While data moves, the plists leave `~/Library/LaunchAgents` and `<cache>/migration.lock` stops the worker, `install.py` and the launcher. Original source versions are never rewritten.

The viewer is read-only, binds only to loopback, rejects foreign Host/Origin headers, validates file paths, and serves audio with byte ranges. It supports full-archive search, source filters, pagination, raw/clean text, attachments, grouped source fields, and every retained metadata version. It does not send data to a hosted service.

## Verification

```sh
python3 -m unittest discover -s scripts/archive -p 'test_*.py' -v
```

Tests cover oversized audio, null dates, arbitrary typed fields, dictionary preservation, original hash preservation, retry after missing files, retention after source deletion, index rebuilding, pagination, search, audio byte ranges, path traversal, and cross-origin access.
