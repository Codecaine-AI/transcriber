// The nightly copy of the transcripts database to the transcripts share, and its checks.
//   bun src/backup.ts [--day YYYY-MM-DD]   copy the database to db/transcripts-<day>.sqlite and
//                                          db/transcripts-<day>.jsonl.gz on the share
//   bun src/backup.ts --restore-check      restore the newest copy from the share and check it
//   bun src/backup.ts --jsonl-check        rebuild the newest matching JSONL and check it
// hub-run runs the copy once a day from 03:00 local time, outside the NAS window, then both checks.
// The copy: VACUUM INTO a local file (a consistent snapshot while the hub writes), an integrity
// check, then the share through a temp file, a rename and a read-back. The JSONL export of that
// snapshot (export.ts) goes to the share the same way. The manifest db/transcripts-<day>.json
// (SHA-256, bytes, row counts, and the JSONL SHA-256 and line count) goes last, so a copy with a
// manifest is whole.
// The history stays: a count below the highest count in any manifest, or a JSONL that does not
// hold every row, exits 1 and prunes nothing. Otherwise the share drops SQLite copies older than
// 30 days, and HUB_BACKUP_DIR keeps the newest 7. Manifests and JSONL files are never removed.
// The restore check reads the newest copy back from the share into a temp folder. It checks the
// SHA-256 against the manifest, the integrity, the row counts and the keyword index, and that every
// row of the copy is in the live database (the hub never deletes a row).
// The JSONL check takes the newest manifest whose counts are the live counts, rebuilds its JSONL
// into an empty database in a temp folder, and compares the counts and the text hash with the live
// database.
// Settings: HUB_DB and HUB_SHARE (as main.ts), HUB_BACKUP_DIR (default ~/data/transcripts/backups).
// One JSON line to stdout. Exit 0 when done, 75 when the NAS window or a missing share stopped it,
// 1 on any other error.
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

/// The share removes a SQLite copy once its day is more than this many days before the new day.
const KEEP_ON_SHARE_DAYS = 30;
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
type Jsonl = { name: string; sha256: Sha256; bytes: number; lines: number };
/// A manifest that cp2 wrote has devices in counts and a jsonl entry. Older ones have neither.
type Manifest = {
  name: string;
  sha256: Sha256;
  bytes: number;
  created_at: string;
  counts: Partial<Counts>;
  jsonl?: Jsonl;
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

/// The reasons this copy must not prune: a count below the highest count in any manifest, or a
/// table row that the JSONL does not hold.
function problems(rowCounts: Counts, top: Partial<Counts>, covered: Covered): string[] {
  const out: string[] = [];
  for (const t of TABLES) {
    const high = top[t];
    if (high !== undefined && rowCounts[t] < high)
      out.push(`${t} has ${rowCounts[t]} rows, below the ${high} of an earlier manifest`);
    if (covered[t] !== rowCounts[t])
      out.push(`the JSONL holds ${covered[t]} of the ${rowCounts[t]} ${t} rows`);
  }
  if (covered.lines !== rowCounts.recordings)
    out.push(`the JSONL has ${covered.lines} lines for ${rowCounts.recordings} recordings`);
  return out;
}

async function backup(day: string) {
  const name = `transcripts-${day}.sqlite`;
  const jsonlName = `transcripts-${day}.jsonl.gz`;
  const manifestPath = `db/transcripts-${day}.json`;
  const before = await manifests();
  const done = before.find((m) => m.day === day)?.manifest;
  if (
    done?.jsonl &&
    (await share.hash(`db/${name}`)) === done.sha256 &&
    (await share.hash(`db/${done.jsonl.name}`)) === done.jsonl.sha256
  )
    return { event: "backup", day, result: "exists", sha256: done.sha256 };

  mkdirSync(localDir, { recursive: true, mode: 0o700 });
  chmodSync(localDir, 0o700);
  const temp = join(localDir, `.${name}.tmp`);
  rmSync(temp, { force: true });
  const live = new Database(dbPath, { readonly: true });
  try {
    live.run("VACUUM INTO ?", [temp]);
  } finally {
    live.close();
  }
  chmodSync(temp, 0o600);
  const rowCounts = checkCopy(temp);
  const bytes = readFileSync(temp);
  const sha = sha256Hex(bytes);
  const localCopy = join(localDir, name);
  renameSync(temp, localCopy);

  // The JSONL export of the same snapshot, made locally and removed after the upload.
  const jsonlTemp = join(localDir, `.${jsonlName}.tmp`);
  rmSync(jsonlTemp, { force: true });
  try {
    const covered = await exportJsonl(localCopy, jsonlTemp);
    const jsonlBytes = readFileSync(jsonlTemp);
    const jsonl: Jsonl = {
      name: jsonlName,
      sha256: sha256Hex(jsonlBytes),
      bytes: jsonlBytes.length,
      lines: covered.lines,
    };
    const { wrote } = await share.putFile(`db/${name}`, bytes, sha);
    await share.putFile(`db/${jsonlName}`, jsonlBytes, jsonl.sha256);

    // A drop or a JSONL gap leaves the copy and the JSONL on the share, but writes no manifest
    // (so the highest counts stay on record) and prunes nothing.
    const found = problems(rowCounts, highest(before), covered);
    if (found.length) throw new Error(`nothing is pruned: ${found.join("; ")}`);

    const manifest: Manifest = {
      name,
      sha256: sha,
      bytes: bytes.length,
      created_at: new Date().toISOString(),
      counts: rowCounts,
      jsonl,
    };
    const text = new TextEncoder().encode(`${JSON.stringify(manifest, null, 1)}\n`);
    await share.putFile(manifestPath, text, sha256Hex(text));

    // Only SQLite copies go, and only those older than 30 days. Manifests and JSONL files stay.
    const oldest = daysBefore(day, KEEP_ON_SHARE_DAYS);
    const pruned = daysOf(await share.list("db"), COPY).filter((d) => d < oldest && d !== day);
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
      jsonl,
      pruned,
      pruned_local: prunedLocal,
    };
  } finally {
    rmSync(jsonlTemp, { force: true });
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

async function jsonlCheck() {
  // The live counts and text hash from one read transaction.
  const liveDb = new Database(dbPath, { readonly: true, strict: true });
  let live: { counts: Counts; text_sha256: string };
  try {
    live = liveDb.transaction(() => ({ counts: counts(liveDb), text_sha256: textHash(liveDb) }))();
  } finally {
    liveDb.close();
  }
  const pick = (await manifests())
    .reverse()
    .find((m) => m.manifest.jsonl && TABLES.every((t) => m.manifest.counts[t] === live.counts[t]));
  const jsonl = pick?.manifest.jsonl;
  if (!pick || !jsonl)
    throw new Error(`no JSONL on the share has the live counts ${JSON.stringify(live.counts)}`);
  const bytes = await share.read(`db/${jsonl.name}`);
  if (sha256Hex(bytes) !== jsonl.sha256 || bytes.length !== jsonl.bytes)
    throw new Error(`db/${jsonl.name} on the share does not match its manifest`);

  const dir = mkdtempSync(join(tmpdir(), "transcripts-jsonl-"));
  try {
    const gz = join(dir, jsonl.name);
    writeFileSync(gz, bytes, { mode: 0o600 });
    const path = join(dir, "rebuilt.sqlite");
    const covered = await rebuildJsonl(gz, path);
    if (covered.lines !== jsonl.lines)
      throw new Error(`the JSONL has ${covered.lines} lines, not the manifest's ${jsonl.lines}`);
    const rebuilt = checkCopy(path);
    const db = new Database(path, { readonly: true, strict: true });
    let text: string;
    let found: number;
    try {
      text = textHash(db);
      found =
        db
          .query<{ n: number }, []>(
            "select count(*) n from cleanups_fts where cleanups_fts match 'the'",
          )
          .get()?.n ?? 0;
    } finally {
      db.close();
    }
    const off = TABLES.filter((t) => rebuilt[t] !== live.counts[t]);
    if (off.length)
      throw new Error(
        `the rebuilt counts differ from the live ones in ${off.join(", ")}: ${JSON.stringify(rebuilt)}`,
      );
    if (text !== live.text_sha256)
      throw new Error("the rebuilt text hash is not the live database's text hash");
    if (found === 0) throw new Error("the rebuilt keyword index finds no cleanup for 'the'");
    return {
      event: "jsonl_check",
      day: pick.day,
      result: "ok",
      jsonl_sha256: jsonl.sha256,
      lines: covered.lines,
      counts: rebuilt,
      text_sha256: text,
      keyword_hits_for_the: found,
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const event = values["jsonl-check"]
  ? "jsonl_check"
  : values["restore-check"]
    ? "restore_check"
    : "backup";
const say = (line: Record<string, unknown>) =>
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`);
try {
  const day = values.day ?? localDay(new Date());
  if (!DAY.test(day)) throw new Error("--day must be YYYY-MM-DD");
  say(
    event === "jsonl_check"
      ? await jsonlCheck()
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
