// The JSONL export of the transcripts database, and its rebuild into an empty database.
// One line per recording, in recordings rowid order:
//   { recording, device, transcriptions, cleanups, audio }
// recording: every column of the recordings row. device: the devices row of recording.device_id
// whose owner period holds recorded_at (else the nearest one), or null when there is none.
// transcriptions and cleanups: every row of the recording, in rowid order. audio: the audio row of
// recording.audio_sha256, or null for a text-only take. Each row keeps every column, so a column
// that schema.sql adds later goes into the export with no change here.
// The rebuild needs only a JSONL file and schema.sql. It restores devices, audio, recordings,
// transcriptions and cleanups, and the cleanups_ai trigger fills cleanups_fts again. A devices row
// that no recording points to, or an audio row that no recording points to, is not in the export:
// the export counts what it holds, and backup.ts compares that with the table counts.
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { createReadStream, createWriteStream, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { createGunzip, createGzip } from "node:zlib";

type Value = string | number | null;
type Row = Record<string, Value>;
export type JsonlLine = {
  recording: Row;
  device: Row | null;
  transcriptions: Row[];
  cleanups: Row[];
  audio: Row | null;
};
/// The rows that a JSONL file holds, per table, with each devices and audio row once.
export type Covered = {
  lines: number;
  devices: number;
  audio: number;
  recordings: number;
  transcriptions: number;
  cleanups: number;
};

export const SCHEMA = new URL("../schema.sql", import.meta.url);

/// The lines of the export, read one recording at a time from the database.
function* lines(db: Database, covered: Covered): Generator<string> {
  const device = db.query<Row, [Value, Value, Value]>(
    'select * from devices where device_id = ? order by "from" <= coalesce(?, "from") desc,' +
      ' case when "from" <= coalesce(?, "from") then "from" end desc, "from" limit 1',
  );
  const transcriptions = db.query<Row, [Value]>(
    "select * from transcriptions where recording_id = ? order by rowid",
  );
  const cleanups = db.query<Row, [Value]>(
    "select * from cleanups where recording_id = ? order by rowid",
  );
  const audio = db.query<Row, [Value]>("select * from audio where sha256 = ?");
  const devices = new Set<string>();
  const audios = new Set<string>();
  for (const recording of db.query<Row, []>("select * from recordings order by rowid").iterate()) {
    const id = recording.recording_id ?? null;
    const at = recording.recorded_at ?? null;
    const sha = recording.audio_sha256 ?? null;
    const line: JsonlLine = {
      recording,
      device: device.get(recording.device_id ?? null, at, at),
      transcriptions: transcriptions.all(id),
      cleanups: cleanups.all(id),
      audio: sha === null ? null : audio.get(sha),
    };
    if (line.device) devices.add(JSON.stringify([line.device.device_id, line.device.from]));
    if (line.audio) audios.add(String(line.audio.sha256));
    covered.lines += 1;
    covered.recordings += 1;
    covered.transcriptions += line.transcriptions.length;
    covered.cleanups += line.cleanups.length;
    covered.devices = devices.size;
    covered.audio = audios.size;
    yield `${JSON.stringify(line)}\n`;
  }
}

/// Write the export of the database at dbPath to a gzip file at out. The rows stream from the
/// database to the file, so only one recording is in memory at a time.
export async function exportJsonl(dbPath: string, out: string): Promise<Covered> {
  const covered: Covered = {
    lines: 0,
    devices: 0,
    audio: 0,
    recordings: 0,
    transcriptions: 0,
    cleanups: 0,
  };
  const db = new Database(dbPath, { readonly: true, strict: true });
  try {
    await pipeline(
      Readable.from(lines(db, covered)),
      createGzip(),
      createWriteStream(out, { mode: 0o600 }),
    );
  } finally {
    db.close();
  }
  return covered;
}

const isValue = (v: unknown): v is Value =>
  v === null || typeof v === "string" || typeof v === "number";
const isRow = (v: unknown): v is Row =>
  typeof v === "object" && v !== null && !Array.isArray(v) && Object.values(v).every(isValue);
const isRows = (v: unknown): v is Row[] => Array.isArray(v) && v.every(isRow);

/// Parse one JSONL line, or throw when it does not have the export's shape.
function parseLine(text: string, at: number): JsonlLine {
  const v: unknown = JSON.parse(text);
  if (
    typeof v === "object" &&
    v !== null &&
    "recording" in v &&
    isRow(v.recording) &&
    "device" in v &&
    (v.device === null || isRow(v.device)) &&
    "transcriptions" in v &&
    isRows(v.transcriptions) &&
    "cleanups" in v &&
    isRows(v.cleanups) &&
    "audio" in v &&
    (v.audio === null || isRow(v.audio))
  )
    return {
      recording: v.recording,
      device: v.device,
      transcriptions: v.transcriptions,
      cleanups: v.cleanups,
      audio: v.audio,
    };
  throw new Error(`line ${at} of the JSONL is not a recording line`);
}

/// The columns of a table, to check each JSONL key before it goes into SQL.
function columnsOf(db: Database, table: string): Set<string> {
  return new Set(
    db
      .query<{ name: string }, []>(`select name from pragma_table_info('${table}')`)
      .all()
      .map((r) => r.name),
  );
}

/// Rebuild the gzip JSONL file at jsonl into a new database at out, made from schema.sql. A
/// devices or audio row that two lines hold goes in once. Throws on a key that is not a column.
export async function rebuildJsonl(jsonl: string, out: string): Promise<Covered> {
  const db = new Database(out, { create: true, strict: true });
  try {
    db.run(readFileSync(SCHEMA, "utf8"));
    const columns = Object.fromEntries(
      ["devices", "audio", "recordings", "transcriptions", "cleanups"].map((t) => [
        t,
        columnsOf(db, t),
      ]),
    );
    const statements = new Map<string, ReturnType<Database["query"]>>();
    const insert = (table: string, row: Row, verb: "insert" | "insert or ignore") => {
      const keys = Object.keys(row);
      const bad = keys.find((k) => !columns[table]?.has(k));
      if (bad !== undefined)
        throw new Error(`the JSONL has ${table}.${bad}, which is not a column`);
      const sql = `${verb} into ${table}(${keys.map((k) => `"${k}"`).join(", ")}) values (${keys.map(() => "?").join(", ")})`;
      let statement = statements.get(sql);
      if (!statement) {
        statement = db.query(sql);
        statements.set(sql, statement);
      }
      statement.run(...Object.values(row));
    };
    const covered: Covered = {
      lines: 0,
      devices: 0,
      audio: 0,
      recordings: 0,
      transcriptions: 0,
      cleanups: 0,
    };
    const input = createInterface({
      input: createReadStream(jsonl).pipe(createGunzip()),
      crlfDelay: Infinity,
    });
    db.run("BEGIN");
    try {
      for await (const text of input) {
        if (text === "") continue;
        const line = parseLine(text, covered.lines + 1);
        if (line.device) insert("devices", line.device, "insert or ignore");
        if (line.audio) insert("audio", line.audio, "insert or ignore");
        insert("recordings", line.recording, "insert");
        for (const t of line.transcriptions) insert("transcriptions", t, "insert");
        for (const c of line.cleanups) insert("cleanups", c, "insert");
        covered.lines += 1;
      }
      db.run("COMMIT");
    } catch (error) {
      db.run("ROLLBACK");
      throw error;
    }
    const one = (table: string) =>
      db.query<{ n: number }, []>(`select count(*) n from ${table}`).get()?.n ?? 0;
    covered.devices = one("devices");
    covered.audio = one("audio");
    covered.recordings = one("recordings");
    covered.transcriptions = one("transcriptions");
    covered.cleanups = one("cleanups");
    // schema.sql turns on WAL. A WAL file with no -shm beside it cannot open read-only.
    db.run("PRAGMA journal_mode = DELETE");
    return covered;
  } finally {
    db.close();
  }
}

/// SHA-256 over the text columns of a database: each transcription's text and words and each
/// cleanup's status and text, with its ID, in ID order. The same rows give the same hash in any
/// database, whatever their rowids.
export function textHash(db: Database): string {
  const h = createHash("sha256");
  for (const r of db
    .query<Row, []>(
      "select transcription_id, text, words from transcriptions order by transcription_id",
    )
    .iterate())
    h.update(`${JSON.stringify(["t", r.transcription_id, r.text, r.words])}\n`);
  for (const r of db
    .query<Row, []>("select cleanup_id, status, text from cleanups order by cleanup_id")
    .iterate())
    h.update(`${JSON.stringify(["c", r.cleanup_id, r.status, r.text])}\n`);
  return h.digest("hex");
}
