// The daily sync of this machine's Transcriber archive to the Transcriber Hub.
//   bun src/main.ts [--since <ISO time>] [--only <recording_id>] [--dry-run]
//                   [--hub <url,url>] [--pin sha256/<base64>]
//   bun src/main.ts --delete-dry-run [--out <file.json>]
// It reads the Transcriber and the Wispr Flow records of ~/Transcripts/records.
// --delete-dry-run lists the records the 30-day local delete would let go (delete-dry-run.ts) in a
// JSON file, and logs the counts by reason. It sends no records and deletes nothing.
// Settings: ~/.config/transcriber-hub-client/{config.json, hub-cert.pem, token (mode 600)}.
// Confirms: ~/.local/state/transcriber-hub-client/confirms.sqlite.
// Log: one JSON line per record and one per run, to ~/Library/Logs/transcriber-hub-sync.log and stdout.
// --hub and --pin replace the configured addresses and pin for one run (live checks).
// Exit 0 when the run finished, 75 when it stopped early (the rest wait for the next run), 1 on error.
import { appendFileSync, chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { stamp } from "../../../Hub/src/ids.ts";
import { loadTarget } from "./config.ts";
import { ConfirmStore } from "./confirms.ts";
import { deleteDryRun } from "./delete-dry-run.ts";
import { assertHttps } from "./hub-client.ts";
import { runSync } from "./sync.ts";

const home = homedir();
const { values } = parseArgs({
  options: {
    since: { type: "string" },
    only: { type: "string" },
    "dry-run": { type: "boolean", default: false },
    "delete-dry-run": { type: "boolean", default: false },
    out: { type: "string" },
    hub: { type: "string" },
    pin: { type: "string" },
    config: { type: "string", default: join(home, ".config/transcriber-hub-client") },
    archive: { type: "string", default: join(home, "Transcripts") },
    state: {
      type: "string",
      default: join(home, ".local/state/transcriber-hub-client/confirms.sqlite"),
    },
    log: { type: "string", default: join(home, "Library/Logs/transcriber-hub-sync.log") },
  },
  strict: true,
});

function log(line: Record<string, unknown>) {
  const text = `${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`;
  appendFileSync(values.log, text, { mode: 0o600 });
  process.stdout.write(text);
}

try {
  if (values.since) stamp(values.since); // refuse a bad time before anything else
  if (values.hub) assertHttps(values.hub.split(",")); // refuse an http override before the config is read
  const target = await loadTarget(values.config, { hub: values.hub, pin: values.pin });
  assertHttps(target.addresses); // before anything is read or sent
  const store = new ConfirmStore(values.state);
  if (values["delete-dry-run"]) {
    const result = await deleteDryRun({ archiveRoot: values.archive, store, target }).finally(() =>
      store.close(),
    );
    const out =
      values.out ??
      join(
        home,
        ".local/state/transcriber-hub-client",
        `delete-dry-run-${new Date().toISOString().replaceAll(":", "")}.json`,
      );
    mkdirSync(dirname(out), { recursive: true, mode: 0o700 });
    // mode only applies to a new file, so make an existing report owner-only before writing.
    if (existsSync(out)) chmodSync(out, 0o600);
    writeFileSync(
      out,
      `${JSON.stringify({ generated_at: new Date().toISOString(), ...result }, null, 1)}\n`,
      {
        mode: 0o600,
      },
    );
    const { entries, ...summary } = result;
    log({ event: "delete_dry_run", ...summary, records: entries.length, out });
    process.exit(result.stopped ? 75 : 0);
  }
  const summary = await runSync({
    archiveRoot: values.archive,
    store,
    target,
    since: values.since ?? null,
    only: values.only ?? null,
    dryRun: values["dry-run"],
    log,
  }).finally(() => store.close());
  log({
    ...summary,
    since: values.since ?? null,
    only: values.only ?? null,
    dry_run: values["dry-run"],
  });
  process.exit(summary.stopped ? 75 : 0);
} catch (error) {
  log({
    event: "run",
    error: (error instanceof Error ? error.message : String(error)).slice(0, 300),
  });
  process.exit(1);
}
