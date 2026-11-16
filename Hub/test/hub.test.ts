// The hub against a temp folder that stands in for the share and a temp database built from
// schema.sql. No network and no NAS: the tests call the fetch handler directly.
import { Database } from "bun:sqlite";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHub } from "../src/hub.ts";
import type { DeviceId, RecordPost } from "../src/record.ts";
import { SHARE_MARKER } from "../src/share.ts";
import { openStore } from "../src/store.ts";
import { addToken, readTokens, revokeDevice, writeTokens } from "../src/tokens.ts";

const MACBOOK = "05d8dedd-c925-4924-8db9-45f3e7452d34" as DeviceId;
const OTHER = "hub-test-device" as DeviceId;
const MAC_TOKEN = randomBytes(30).toString("base64url");
const OTHER_TOKEN = randomBytes(30).toString("base64url");
const OPEN = new Date("2026-11-16T09:00:00Z");

const sha = (data: Uint8Array | string) => createHash("sha256").update(data).digest("hex");

/// A mono FLAC header (fLaC + STREAMINFO, 16 kHz, 1 channel, 16 bit) and a random body.
function makeFlac(channels = 1): Uint8Array {
  const head = new Uint8Array(42);
  head.set([0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, 34]);
  const si = head.subarray(8);
  // sample rate 16000 = 0x03e80 in 20 bits, channels - 1 in 3 bits, bits per sample - 1 (15) in 5 bits
  si[10] = 0x03;
  si[11] = 0xe8;
  si[12] = (0x0 << 4) | ((channels - 1) << 1) | (15 >> 4);
  si[13] = (15 & 0x0f) << 4;
  return new Uint8Array([...head, ...randomBytes(4096)]);
}

let dir: string;
let share: string;
let dbPath: string;
let tokensPath: string;
let db: Database;
let logs: string[];
let now: Date;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "hub-test-"));
  share = join(dir, "share");
  await Bun.write(join(share, SHARE_MARKER), "{}\n");
  dbPath = join(dir, "transcripts.sqlite");
  const init = new Database(dbPath);
  init.exec(await Bun.file(join(import.meta.dir, "../schema.sql")).text());
  init.close();
  db = openStore(dbPath);
  tokensPath = join(dir, "tokens.json");
  await writeTokens(tokensPath, addToken(addToken({}, MACBOOK, MAC_TOKEN), OTHER, OTHER_TOKEN));
  logs = [];
  now = OPEN;
});

afterEach(async () => {
  db.close();
  await rm(dir, { recursive: true, force: true });
});

function hub(faults = {}) {
  return createHub({
    db,
    shareRoot: share,
    tokensPath,
    clock: () => now,
    log: (l) => logs.push(l),
    faults,
  });
}

function record(
  flac: Uint8Array | null = makeFlac(),
  id = crypto.randomUUID().toUpperCase(),
): RecordPost {
  return {
    recording: {
      recording_id: id,
      recorded_at: "2026-11-16T08:12:03Z",
      device_id: MACBOOK,
      mode: "dictation",
      status: "completed",
      language: "en",
      app: "com.apple.Notes",
      duration_seconds: 4.2,
    },
    transcription: {
      provider: "Deepgram",
      model: "nova-3",
      model_version: null,
      settings: { vocabulary: "", language: "en" },
      processing_seconds: 0.8,
      detected_language: "en",
      text: "the quick brown fox it's raw",
    },
    cleanup: {
      engine: "Transcriber",
      engine_version: "1.0",
      model: "Qwen3-4B-Instruct-2507",
      model_sha256: null,
      prompt_sha256: null,
      status: "completed",
      text: "The quick brown fox, it's clean.",
    },
    audio: flac && {
      sha256: sha(flac),
      source_sha256: sha("wav"),
      source_bytes: 9000,
      sample_rate: 16000,
      frame_count: 2048,
      flac_base64: Buffer.from(flac).toString("base64"),
    },
  };
}

const post = (h: ReturnType<typeof hub>, body: unknown, token: string | null = MAC_TOKEN) =>
  h.fetch(
    new Request("https://hub.test/v1/records", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    }),
  );

const reconfirm = (h: ReturnType<typeof hub>, id: string, held: unknown, token = MAC_TOKEN) =>
  h.fetch(
    new Request(`https://hub.test/v1/records/${id}/reconfirm`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
      body: JSON.stringify(held),
    }),
  );

const searchFor = (h: ReturnType<typeof hub>, q: string, token = MAC_TOKEN) =>
  h.fetch(
    new Request(`https://hub.test/v1/search?q=${encodeURIComponent(q)}`, {
      headers: { authorization: `Bearer ${token}` },
    }),
  );

async function shareFiles(): Promise<string[]> {
  try {
    return (await readdir(join(share, "artifacts"), { recursive: true }))
      .map(String)
      .filter((p) => p.endsWith(".flac") && !p.split("/").pop()!.startsWith("."));
  } catch {
    return [];
  }
}

const counts = () =>
  Object.fromEntries(
    ["recordings", "audio", "transcriptions", "cleanups"].map((t) => [
      t,
      db.query<{ n: number }, []>(`select count(*) n from ${t}`).get()!.n,
    ]),
  );

const ONE_SET = { recordings: 1, audio: 1, transcriptions: 1, cleanups: 1 };
const NOTHING = { recordings: 0, audio: 0, transcriptions: 0, cleanups: 0 };

test("a good post writes the FLAC and the rows and confirms the stored hashes", async () => {
  const body = record();
  const res = await post(hub(), body);
  expect(res.status).toBe(200);
  const confirm = await res.json();
  const id = body.recording.recording_id.toLowerCase();
  expect(confirm).toEqual({
    recording_id: id,
    flac_sha256: body.audio!.sha256,
    text_sha256: { raw: sha(body.transcription!.text), clean: sha(body.cleanup!.text) },
  });
  const path = `artifacts/${body.audio!.sha256.slice(0, 2)}/${body.audio!.sha256}.flac`;
  expect(sha(new Uint8Array(await Bun.file(join(share, path)).arrayBuffer()))).toBe(
    body.audio!.sha256,
  );
  expect(counts()).toEqual(ONE_SET);
  const rec = db.query("select device_id, recorded_at, audio_sha256 from recordings").get();
  expect(rec).toEqual({
    device_id: MACBOOK,
    recorded_at: "2026-11-16T08:12:03.000Z",
    audio_sha256: body.audio!.sha256,
  });
  expect(db.query("select nas_path, bytes from audio").get()).toEqual({
    nas_path: path,
    bytes: 4138,
  });
  expect(db.query("select settings from transcriptions").get()).toEqual({
    settings: '{"language": "en", "vocabulary": ""}',
  });
});

test("a replay changes nothing and returns the same confirm", async () => {
  const h = hub();
  const body = record();
  const first = await (await post(h, body)).json();
  const changes = db.query<{ n: number }, []>("select total_changes() n").get()!.n;
  const res = await post(h, body);
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual(first);
  expect(db.query<{ n: number }, []>("select total_changes() n").get()!.n).toBe(changes);
  expect(await shareFiles()).toHaveLength(1);
  expect(counts()).toEqual(ONE_SET);
});

test("FLAC bytes that do not hash to the claimed SHA-256 are refused and nothing is written", async () => {
  const body = record();
  body.audio!.sha256 = sha("other bytes");
  const res = await post(hub(), body);
  expect(res.status).toBe(400);
  expect((await res.json()).error).toBe("bad_hash");
  expect(await shareFiles()).toEqual([]);
  expect(counts()).toEqual(NOTHING);
});

test("a missing, a wrong and a revoked token are refused", async () => {
  const h = hub();
  expect((await post(h, record(), null)).status).toBe(401);
  expect((await post(h, record(), randomBytes(30).toString("base64url"))).status).toBe(401);
  await writeTokens(tokensPath, revokeDevice(await readTokens(tokensPath), OTHER));
  const body = record();
  body.recording.device_id = null;
  expect((await post(h, body, OTHER_TOKEN)).status).toBe(401);
  expect((await searchFor(h, "fox", OTHER_TOKEN)).status).toBe(401);
  expect(await shareFiles()).toEqual([]);
  expect(counts()).toEqual(NOTHING);
});

test("a token of one device that posts a record of another device is refused", async () => {
  const h = hub();
  const res = await post(h, record(), OTHER_TOKEN);
  expect(res.status).toBe(403);
  expect((await res.json()).error).toBe("device_mismatch");
  expect(counts()).toEqual(NOTHING);
  // A recording the MacBook stored cannot be posted again or reconfirmed with the other token.
  const body = record();
  await post(h, body);
  body.recording.device_id = null;
  expect((await post(h, body, OTHER_TOKEN)).status).toBe(403);
  expect(
    (
      await reconfirm(
        h,
        body.recording.recording_id,
        { flac_sha256: null, text_sha256: {} },
        OTHER_TOKEN,
      )
    ).status,
  ).toBe(403);
  expect(db.query("select device_id from recordings").all()).toEqual([{ device_id: MACBOOK }]);
});

test("a post cut off after the file write and before the confirm is resent into 1 file and 1 set of rows", async () => {
  const body = record();
  let crash = true;
  const h = hub({
    afterFileWrite: () => {
      if (crash) throw new Error("connection lost");
    },
  });
  expect((await post(h, body)).status).toBe(500);
  expect(await shareFiles()).toHaveLength(1);
  expect(counts()).toEqual(NOTHING);
  crash = false;
  const res = await post(h, body);
  expect(res.status).toBe(200);
  expect((await res.json()).flac_sha256).toBe(body.audio!.sha256);
  expect(await shareFiles()).toHaveLength(1);
  expect(counts()).toEqual(ONE_SET);
});

test("a cancelled take with no audio and no text is stored and confirmed with empty hashes", async () => {
  const body = { ...record(null), transcription: null, cleanup: null };
  const res = await post(hub(), body);
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({
    recording_id: body.recording.recording_id.toLowerCase(),
    flac_sha256: null,
    text_sha256: { raw: null, clean: null },
  });
  expect(counts()).toEqual({ recordings: 1, audio: 0, transcriptions: 0, cleanups: 0 });
});

test("a stereo FLAC is refused", async () => {
  expect((await post(hub(), record(makeFlac(2)))).status).toBe(400);
  expect(counts()).toEqual(NOTHING);
});

test("reconfirm passes for the stored record and lists a changed FLAC and a changed text", async () => {
  const h = hub();
  const body = record();
  const confirm = await (await post(h, body)).json();
  const { recording_id, ...held } = confirm;
  expect(await (await reconfirm(h, recording_id, held)).json()).toEqual({ ok: true });

  const path = join(
    share,
    `artifacts/${body.audio!.sha256.slice(0, 2)}/${body.audio!.sha256}.flac`,
  );
  await writeFile(path, makeFlac());
  const flacCheck = await (await reconfirm(h, recording_id, held)).json();
  expect(flacCheck.ok).toBe(false);
  expect(flacCheck.mismatches.map((m: { field: string }) => m.field)).toEqual(["flac_file"]);

  db.query("update cleanups set text = 'changed'").run();
  const textCheck = await (await reconfirm(h, recording_id, held)).json();
  expect(textCheck.mismatches.map((m: { field: string }) => m.field)).toEqual([
    "flac_file",
    "clean",
  ]);

  const unknown = await (await reconfirm(h, crypto.randomUUID(), held)).json();
  expect(unknown).toEqual({
    ok: false,
    mismatches: [expect.objectContaining({ field: "recording", found: null })],
  });
});

test("search fuses BM25 and exact-phrase hits and maps them to recording IDs", async () => {
  const h = hub();
  const phrase = record(null);
  phrase.cleanup!.text = "please order the blue widget today";
  const scattered = record(null);
  scattered.cleanup!.text = "blue sky, order soup, widget broken, blue blue widget";
  const unrelated = record(null);
  unrelated.cleanup!.text = "nothing to see here";
  for (const b of [scattered, phrase, unrelated]) expect((await post(h, b)).status).toBe(200);
  const res = await searchFor(h, "Blue Widget!");
  expect(res.status).toBe(200);
  const { results } = await res.json();
  expect(results.map((r: { recording_id: string }) => r.recording_id)).toEqual([
    phrase.recording.recording_id.toLowerCase(),
    scattered.recording.recording_id.toLowerCase(),
  ]);
  expect(results[0].score).toBeCloseTo(2 / 61);
  expect(results[0].recorded_at).toBe("2026-11-16T08:12:03.000Z");
  // The tokenizer keeps "it's" as one word, so "its" does not find it.
  const withIts = record(null);
  expect((await post(h, withIts)).status).toBe(200);
  const its = await (await searchFor(h, "it's")).json();
  expect(its.results.map((r: { recording_id: string }) => r.recording_id)).toEqual([
    withIts.recording.recording_id.toLowerCase(),
  ]);
  expect((await (await searchFor(h, "its")).json()).results).toEqual([]);
  expect((await searchFor(h, "")).status).toBe(400);
});

test("from 10:57 to 12:00 UTC every share route answers 503 with Retry-After and writes nothing", async () => {
  const h = hub();
  const body = record();
  now = new Date("2026-11-16T11:00:00Z");
  const res = await post(h, body);
  expect(res.status).toBe(503);
  expect(res.headers.get("retry-after")).toBe("3600");
  expect(
    (await reconfirm(h, body.recording.recording_id, { flac_sha256: null, text_sha256: {} }))
      .status,
  ).toBe(503);
  expect(await shareFiles()).toEqual([]);
  expect(counts()).toEqual(NOTHING);
  // Search reads only the database, so it keeps working.
  expect((await searchFor(h, "fox")).status).toBe(200);
  now = new Date("2026-11-16T10:56:59Z");
  expect((await post(h, body)).status).toBe(200);
  now = new Date("2026-11-16T12:00:00Z");
  expect((await post(h, body)).status).toBe(200);
});

test("a post that runs into the window stops at its next share step", async () => {
  const body = record();
  const h = hub({
    afterFileWrite: () => {
      now = new Date("2026-11-16T10:57:00Z");
    },
  });
  now = new Date("2026-11-16T10:56:59Z");
  const res = await post(h, body);
  expect(res.status).toBe(503);
  expect(res.headers.get("retry-after")).toBe("3780");
  expect(counts()).toEqual(NOTHING);
  now = new Date("2026-11-16T12:00:01Z");
  expect((await post(hub(), body)).status).toBe(200);
  expect(await shareFiles()).toHaveLength(1);
  expect(counts()).toEqual(ONE_SET);
});

test("a share that is not mounted (no marker) answers 503 and nothing is written to the mount point", async () => {
  await rm(join(share, SHARE_MARKER));
  const res = await post(hub(), record());
  expect(res.status).toBe(503);
  expect((await res.json()).error).toBe("share_unavailable");
  expect(await shareFiles()).toEqual([]);
});

test("healthz answers ok without auth", async () => {
  const res = await hub().fetch(new Request("https://hub.test/healthz"));
  expect(res.status).toBe(200);
  expect(await res.text()).toBe("ok");
});

test("the request log has one line per request and never a token or the Authorization header", async () => {
  const h = hub();
  const body = record();
  await post(h, body);
  await post(h, body, OTHER_TOKEN);
  await post(h, body, null);
  await post(h, body, "wrong-token-wrong-token-wrong-token-wrong");
  await searchFor(h, "secret words");
  await reconfirm(h, body.recording.recording_id, { flac_sha256: null, text_sha256: {} });
  expect(logs).toHaveLength(6);
  const all = logs.join("\n");
  for (const forbidden of [
    MAC_TOKEN,
    OTHER_TOKEN,
    "wrong-token",
    "Bearer",
    "uthorization",
    "secret words",
    "fox",
  ])
    expect(all).not.toContain(forbidden);
  const first = JSON.parse(logs[0]!);
  expect(Object.keys(first).sort()).toEqual([
    "device_id",
    "recording_id",
    "route",
    "status",
    "time",
  ]);
  expect(first).toMatchObject({
    route: "POST /v1/records",
    device_id: MACBOOK,
    status: 200,
    recording_id: body.recording.recording_id.toLowerCase(),
  });
});

test("tokens.json holds only hashes, mode 600", async () => {
  const text = await Bun.file(tokensPath).text();
  expect(text).not.toContain(MAC_TOKEN);
  expect(Object.keys(JSON.parse(text))).toEqual([sha(MAC_TOKEN), sha(OTHER_TOKEN)]);
  expect((await stat(tokensPath)).mode & 0o777).toBe(0o600);
});
