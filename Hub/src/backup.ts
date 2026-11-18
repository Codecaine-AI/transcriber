// The nightly copy of the transcripts database to the transcripts share, and its checks.
//   bun src/backup.ts [--day YYYY-MM-DD]   copy the database to db/transcripts-<day>.sqlite,
//                                          db/transcripts-<day>.jsonl.gz and
//                                          db/transcripts-<day>.rest.json.gz on the share
//   bun src/backup.ts --restore-check      restore the newest copy from the share and check it
//   bun src/backup.ts --jsonl-check        rebuild the newest JSONL that matches the live database
//   bun src/backup.ts --jsonl-check --day YYYY-MM-DD
//                                          rebuild that day's JSONL and check it against its
//                                          manifest (hub-run uses this one)
// hub-run runs the copy once a day from 03:00 local time, outside the NAS window, then both checks.
// The copy: VACUUM INTO a local temp file (a consistent snapshot while the hub writes), an
// integrity check, and the JSONL and rest export of that snapshot (export.ts) into local temp
// files. Every check runs on the temp files first. Only then do the local copy and the share files
// change, each through a temp file, a rename and a read-back. The manifest db/transcripts-<day>.json
// (SHA-256, bytes, row counts, the text hash, and the JSONL and rest SHA-256) goes last, so a copy
// with a manifest is whole.
// The history stays: a count below the highest count in any manifest, or a JSONL and rest file
// that do not hold every row, exits 1 and changes no file. Otherwise the share drops a SQLite copy
// only when it is older than 30 days and not one of the newest 30, and HUB_BACKUP_DIR keeps the
// newest 7. Manifests, JSONL and rest files are never removed. A --day after tomorrow exits 2.
// The restore check reads the newest copy back from the share into a temp folder. It checks the
// SHA-256 against the manifest, the integrity, the row counts and the keyword index, and that every
// row of the copy is in the live database (the hub never deletes a row).
// The JSONL check rebuilds a JSONL and its rest file into an empty database in a temp folder and
// compares the counts and the text hash. With --day, against that day's manifest. Without it,
// against the live database: it tries each manifest with the live counts, newest first, and passes
// on the first match.
// Settings: HUB_DB and HUB_SHARE (as main.ts), HUB_BACKUP_DIR (default ~/data/transcripts/backups).
// One JSON line to stdout. Exit 0 when done, 75 when the NAS window or a missing share stopped it,
// 2 for a --day after tomorrow, 1 on any other error.
import { Database } from "bun:sqlite";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { HttpError } from "./errors.ts";
import { type Covered, exportJsonl, rebuildJsonl, textHash } from "./export.ts";
import { type Sha256, sha256Hex } from "./record.ts";
import { Share } from "./share.ts";

/// The share removes a SQLite copy only when its day is more than this many days before the new
/// day and it is not one of this many newest copies.
const KEEP_ON_SHARE = 30;
/// How long a read of the live database waits for a writer's lock.
const BUSY_TIMEOUT_MS = 5000;
const KEEP_LOCAL = 7;
const TABLES = ["recordings", "transcriptions", "cleanups", "audio", "devices"] as const;
/// The primary key columns of each table, for the restore check.
const KEYS = {
  recordings: ["recording_id"],
  transcriptions: ["transcription_id"],
  cleanups: ["cleanup_id"],
  audio: ["sha256"],
  devices: ["device_id", '"from"'],
} as const;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const COPY = /^transcripts-(\d{4}-\d{2}-\d{2})\.sqlite$/;
const MANIFEST = /^transcripts-(\d{4}-\d{2}-\d{2})\.json$/;

type Table = (typeof TABLES)[number];
type Counts = Record<Table, number>;
type FileEntry = { name: string; sha256: Sha256; bytes: number };
type Jsonl = FileEntry & { lines: number };
/// A manifest that cp2 wrote has devices in counts, a jsonl and a rest entry, and the snapshot's
/// text hash. Older ones have none of them.
type Manifest = {
  name: string;
  sha256: Sha256;
  bytes: number;
  created_at: string;
  counts: Partial<Counts>;
  text_sha256?: string;
  jsonl?: Jsonl;
  rest?: FileEntry;
};

const home = homedir();
const env = (name: string, fallback: string) => process.env[name] || fallback;
const dbPath = env("HUB_DB", join(home, "data/transcripts/transcripts.sqlite"));
const localDir = env("HUB_BACKUP_DIR", join(home, "data/transcripts/backups"));
const share = new Share(env("HUB_SHARE", join(home, "mnt/nas-transcripts")), () => new Date());

const { values } = parseArgs({
  options: {
    day: { type: "string" },
    "restore-check": { type: "boolean", default: false },
    "jsonl-check": { type: "boolean", default: false },
  },
  strict: true,
});

/// The date on this machine's clock, YYYY-MM-DD.
const localDay = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

const daysOf = (names: string[], pattern: RegExp) =>
  names.map((n) => pattern.exec(n)?.[1]).filter((d): d is string => d !== undefined);

/// The day n days before a YYYY-MM-DD day.
const daysBefore = (day: string, n: number) =>
  new Date(Date.parse(`${day}T00:00:00Z`) - n * 86_400_000).toISOString().slice(0, 10);

const entryOf = (name: string, bytes: Uint8Array): FileEntry => ({
  name,
  sha256: sha256Hex(bytes),
  bytes: bytes.length,
});

/// The text hash of a database file.
function textHashOf(path: string): string {
  const db = new Database(path, { readonly: true, strict: true });
  try {
    return textHash(db);
  } finally {
    db.close();
  }
}

function counts(db: Database): Counts {
  const one = (table: string) =>
    db.query<{ n: number }, []>(`select count(*) n from ${table}`).get()?.n ?? 0;
  return Object.fromEntries(TABLES.map((t) => [t, one(t)])) as Counts;
}

/// Open a copy read-only, refuse it unless integrity_check says ok, and return its row counts.
function checkCopy(path: string): Counts {
  const db = new Database(path, { readonly: true, strict: true });
  try {
    const rows = db.query<{ integrity_check: string }, []>("pragma integrity_check").all();
    if (rows.length !== 1 || rows[0]?.integrity_check !== "ok")
      throw new Error(
        `${path} fails the integrity check: ${rows
          .slice(0, 3)
          .map((r) => r.integrity_check)
          .join("; ")}`,
      );
    return counts(db);
  } finally {
    db.close();
  }
}

const readManifest = async (relative: string) =>
  JSON.parse(new TextDecoder().decode(await share.read(relative))) as Manifest;

/// Every manifest on the share, oldest day first.
async function manifests(): Promise<{ day: string; manifest: Manifest }[]> {
  const out = [];
  for (const day of daysOf(await share.list("db"), MANIFEST).sort())
    out.push({ day, manifest: await readManifest(`db/transcripts-${day}.json`) });
  return out;
}

/// The highest count of each table in any manifest.
function highest(all: { manifest: Manifest }[]): Partial<Counts> {
  const top: Partial<Counts> = {};
  for (const { manifest } of all)
    for (const t of TABLES) {
      const n = manifest.counts[t];
      if (n !== undefined && n > (top[t] ?? -1)) top[t] = n;
    }
  return top;
}

/// The reasons this copy must not be written: a count below the highest count in any manifest, or
/// a table row that the JSONL and rest file do not hold.
function problems(rowCounts: Counts, top: Partial<Counts>, covered: Covered): string[] {
  const out: string[] = [];
  for (const t of TABLES) {
    const high = top[t];
    if (high !== undefined && rowCounts[t] < high)
      out.push(`${t} has ${rowCounts[t]} rows, below the ${high} of an earlier manifest`);
    if (covered[t] !== rowCounts[t])
      out.push(`the JSONL and rest file hold ${covered[t]} of the ${rowCounts[t]} ${t} rows`);
  }
  if (covered.lines !== rowCounts.recordings)
    out.push(`the JSONL has ${covered.lines} lines for ${rowCounts.recordings} recordings`);
  return out;
}

async function backup(day: string) {
  const name = `transcripts-${day}.sqlite`;
  const jsonlName = `transcripts-${day}.jsonl.gz`;
  const restName = `transcripts-${day}.rest.json.gz`;
  const manifestPath = `db/transcripts-${day}.json`;
  const before = await manifests();
  const done = before.find((m) => m.day === day)?.manifest;
  if (
    done?.jsonl &&
    done.rest &&
    done.text_sha256 &&
    (await share.hash(`db/${name}`)) === done.sha256 &&
    (await share.hash(`db/${done.jsonl.name}`)) === done.jsonl.sha256 &&
    (await share.hash(`db/${done.rest.name}`)) === done.rest.sha256
  )
    return { event: "backup", day, result: "exists", sha256: done.sha256 };

  mkdirSync(localDir, { recursive: true, mode: 0o700 });
  chmodSync(localDir, 0o700);
  // The snapshot and its export go to temp files. No existing file changes until every check passes.
  const temp = join(localDir, `.${name}.tmp`);
  const jsonlTemp = join(localDir, `.${jsonlName}.tmp`);
  const restTemp = join(localDir, `.${restName}.tmp`);
  const clean = () => {
    for (const path of [temp, jsonlTemp, restTemp]) rmSync(path, { force: true });
  };
  clean();
  try {
    const live = new Database(dbPath, { readonly: true });
    try {
      live.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
      live.run("VACUUM INTO ?", [temp]);
    } finally {
      live.close();
    }
    chmodSync(temp, 0o600);
    const rowCounts = checkCopy(temp);
    const text_sha256 = textHashOf(temp);
    const covered = await exportJsonl(temp, jsonlTemp, restTemp);

    // A drop or a gap refuses the copy before any write, so the highest counts stay on record and
    // every earlier file stays as it was.
    const found = problems(rowCounts, highest(before), covered);
    if (found.length) throw new Error(`nothing is written or pruned: ${found.join("; ")}`);

    const bytes = readFileSync(temp);
    const sha = sha256Hex(bytes);
    const jsonlBytes = readFileSync(jsonlTemp);
    const jsonl: Jsonl = { ...entryOf(jsonlName, jsonlBytes), lines: covered.lines };
    const restBytes = readFileSync(restTemp);
    const rest = entryOf(restName, restBytes);
    renameSync(temp, join(localDir, name));
    const { wrote } = await share.putFile(`db/${name}`, bytes, sha);
    await share.putFile(`db/${jsonlName}`, jsonlBytes, jsonl.sha256);
    await share.putFile(`db/${restName}`, restBytes, rest.sha256);

    const manifest: Manifest = {
      name,
      sha256: sha,
      bytes: bytes.length,
      created_at: new Date().toISOString(),
      counts: rowCounts,
      text_sha256,
      jsonl,
      rest,
    };
    const text = new TextEncoder().encode(`${JSON.stringify(manifest, null, 1)}\n`);
    await share.putFile(manifestPath, text, sha256Hex(text));

    // Only SQLite copies go: those older than 30 days that are not among the newest 30.
    // Manifests, JSONL and rest files stay.
    const oldest = daysBefore(day, KEEP_ON_SHARE);
    const pruned = daysOf(await share.list("db"), COPY)
      .sort()
      .reverse()
      .slice(KEEP_ON_SHARE)
      .filter((d) => d < oldest && d !== day);
    for (const d of pruned) await share.remove(`db/transcripts-${d}.sqlite`);
    const localDays = daysOf(readdirSync(localDir), COPY).sort().reverse();
    const prunedLocal = localDays.slice(KEEP_LOCAL).filter((d) => d !== day);
    for (const d of prunedLocal) rmSync(join(localDir, `transcripts-${d}.sqlite`), { force: true });

    return {
      event: "backup",
      day,
      result: wrote ? "written" : "kept",
      sha256: sha,
      bytes: bytes.length,
      counts: rowCounts,
      text_sha256,
      jsonl,
      rest,
      pruned,
      pruned_local: prunedLocal,
    };
  } finally {
    clean();
  }
}

async function restoreCheck() {
  const day = daysOf(await share.list("db"), MANIFEST)
    .sort()
    .at(-1);
  if (!day) throw new Error("the share holds no database copy with a manifest");
  const manifest = await readManifest(`db/transcripts-${day}.json`);
  const bytes = await share.read(`db/${manifest.name}`);
  const sha = sha256Hex(bytes);
  if (sha !== manifest.sha256 || bytes.length !== manifest.bytes)
    throw new Error(`db/${manifest.name} on the share does not match its manifest`);

  const dir = mkdtempSync(join(tmpdir(), "transcripts-restore-"));
  try {
    const path = join(dir, manifest.name);
    writeFileSync(path, bytes, { mode: 0o600 });
    const restored = checkCopy(path);
    // A manifest from before cp2 has no devices count.
    for (const t of TABLES)
      if (manifest.counts[t] !== undefined && restored[t] !== manifest.counts[t])
        throw new Error(
          `the restored ${t} count ${restored[t]} is not the manifest's ${manifest.counts[t]}`,
        );
    // A read-only main database attaches the live one read-only too.
    const db = new Database(path, { readonly: true, strict: true });
    try {
      const found =
        db
          .query<{ n: number }, []>(
            "select count(*) n from cleanups_fts where cleanups_fts match 'the'",
          )
          .get()?.n ?? 0;
      if (found === 0) throw new Error("the restored keyword index finds no cleanup for 'the'");
      db.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
      db.run("ATTACH DATABASE ? AS live", [dbPath]);
      const missing = Object.fromEntries(
        TABLES.map((t) => [
          t,
          db
            .query<{ n: number }, []>(
              `select count(*) n from main.${t} c where not exists (select 1 from live.${t} l where ${KEYS[t].map((k) => `l.${k} = c.${k}`).join(" and ")})`,
            )
            .get()?.n ?? 0,
        ]),
      ) as Counts;
      const liveCounts = Object.fromEntries(
        TABLES.map((t) => [
          t,
          db.query<{ n: number }, []>(`select count(*) n from live.${t}`).get()?.n ?? 0,
        ]),
      ) as Counts;
      if (TABLES.some((t) => missing[t] > 0))
        throw new Error(
          `rows of the copy are missing in the live database: ${JSON.stringify(missing)}`,
        );
      return {
        event: "restore_check",
        day,
        result: "ok",
        sha256: sha,
        bytes: bytes.length,
        counts: restored,
        live: liveCounts,
        keyword_hits_for_the: found,
      };
    } finally {
      db.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/// Read a day's JSONL and rest file from the share, check them against the manifest, rebuild them
/// into an empty database in a temp folder, and check the rebuilt counts against the manifest.
async function rebuildDay(day: string, manifest: Manifest) {
  const { jsonl, rest } = manifest;
  if (!jsonl || !rest) throw new Error(`the manifest of ${day} has no JSONL and rest file`);
  const dir = mkdtempSync(join(tmpdir(), "transcripts-jsonl-"));
  try {
    const paths = [];
    for (const entry of [jsonl, rest]) {
      const bytes = await share.read(`db/${entry.name}`);
      if (sha256Hex(bytes) !== entry.sha256 || bytes.length !== entry.bytes)
        throw new Error(`db/${entry.name} on the share does not match its manifest`);
      const path = join(dir, entry.name);
      writeFileSync(path, bytes, { mode: 0o600 });
      paths.push(path);
    }
    const [gz = "", restGz = ""] = paths;
    const path = join(dir, "rebuilt.sqlite");
    const covered = await rebuildJsonl(gz, restGz, path);
    if (covered.lines !== jsonl.lines)
      throw new Error(`the JSONL has ${covered.lines} lines, not the manifest's ${jsonl.lines}`);
    const rebuilt = checkCopy(path);
    const off = TABLES.filter((t) => rebuilt[t] !== manifest.counts[t]);
    if (off.length)
      throw new Error(
        `the rebuilt counts differ from the manifest's in ${off.join(", ")}: ${JSON.stringify(rebuilt)}`,
      );
    const db = new Database(path, { readonly: true, strict: true });
    try {
      const found =
        db
          .query<{ n: number }, []>(
            "select count(*) n from cleanups_fts where cleanups_fts match 'the'",
          )
          .get()?.n ?? 0;
      if (found === 0) throw new Error("the rebuilt keyword index finds no cleanup for 'the'");
      return {
        jsonl_sha256: jsonl.sha256,
        lines: covered.lines,
        counts: rebuilt,
        text_sha256: textHash(db),
        keyword_hits_for_the: found,
      };
    } finally {
      db.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/// Rebuild one day's JSONL and check it against its own manifest: what hub-run runs after the
/// copy, so a live write after the copy cannot fail it.
async function jsonlDayCheck(day: string) {
  const manifest = await readManifest(`db/transcripts-${day}.json`);
  if (!manifest.text_sha256) throw new Error(`the manifest of ${day} has no text hash`);
  const result = await rebuildDay(day, manifest);
  if (result.text_sha256 !== manifest.text_sha256)
    throw new Error("the rebuilt text hash is not the manifest's text hash");
  return { event: "jsonl_check", against: "manifest", day, result: "ok", ...result };
}

/// Rebuild the newest JSONL whose counts and text hash are the live database's. Tries each
/// manifest with the live counts, newest first, and fails only when none matches.
async function jsonlLiveCheck() {
  // The live counts and text hash from one read transaction.
  const liveDb = new Database(dbPath, { readonly: true, strict: true });
  let live: { counts: Counts; text_sha256: string };
  try {
    liveDb.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
    live = liveDb.transaction(() => ({ counts: counts(liveDb), text_sha256: textHash(liveDb) }))();
  } finally {
    liveDb.close();
  }
  const candidates = (await manifests())
    .reverse()
    .filter(
      (m) => m.manifest.jsonl && TABLES.every((t) => m.manifest.counts[t] === live.counts[t]),
    );
  const misses: string[] = [];
  for (const { day, manifest } of candidates) {
    if (manifest.text_sha256 !== undefined && manifest.text_sha256 !== live.text_sha256) {
      misses.push(`${day}: its text hash is not the live one`);
      continue;
    }
    try {
      const result = await rebuildDay(day, manifest);
      if (result.text_sha256 === live.text_sha256)
        return { event: "jsonl_check", against: "live", day, result: "ok", ...result };
      misses.push(`${day}: the rebuilt text hash is not the live one`);
    } catch (error) {
      // The NAS window or a missing share stops the check (exit 75). Any other error skips the day.
      if (error instanceof HttpError) throw error;
      misses.push(`${day}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  throw new Error(
    `no JSONL on the share matches the live counts ${JSON.stringify(live.counts)} and text hash${misses.length ? `: ${misses.join("; ")}` : ""}`,
  );
}

const event = values["jsonl-check"]
  ? "jsonl_check"
  : values["restore-check"]
    ? "restore_check"
    : "backup";
const say = (line: Record<string, unknown>) =>
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`);
// A --day after tomorrow on this clock would keep a future manifest forever. Refuse it first.
const tomorrow = localDay(new Date(Date.now() + 86_400_000));
if (values.day !== undefined && DAY.test(values.day) && values.day > tomorrow) {
  say({ event, result: "refused", error: `--day ${values.day} is after tomorrow, ${tomorrow}` });
  process.exit(2);
}
try {
  const day = values.day ?? localDay(new Date());
  if (!DAY.test(day)) throw new Error("--day must be YYYY-MM-DD");
  say(
    event === "jsonl_check"
      ? values.day === undefined
        ? await jsonlLiveCheck()
        : await jsonlDayCheck(day)
      : event === "restore_check"
        ? await restoreCheck()
        : await backup(day),
  );
  process.exit(0);
} catch (error) {
  const stopped = error instanceof HttpError && error.status === 503;
  say({
    event,
    result: stopped ? "stopped" : "failed",
    error: (error instanceof Error ? error.message : String(error)).slice(0, 300),
  });
  process.exit(stopped ? 75 : 1);
}
