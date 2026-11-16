// The sync against temp archive records and a real hub (Hub/src createHub) served over TLS on
// 127.0.0.1 with a certificate made for the test. No outside network, no NAS, no ~/Transcripts.
import { Database } from "bun:sqlite";
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { createHash, randomBytes, randomUUID, X509Certificate } from "node:crypto";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHub } from "../../../Hub/src/hub.ts";
import type { DeviceId } from "../../../Hub/src/record.ts";
import { SHARE_MARKER } from "../../../Hub/src/share.ts";
import { openStore } from "../../../Hub/src/store.ts";
import { addToken, writeTokens } from "../../../Hub/src/tokens.ts";
import { scanWav } from "../src/audio.ts";
import { ConfirmStore } from "../src/confirms.ts";
import { HubClient, spkiPin, StopRun, type HubTarget } from "../src/hub-client.ts";
import { runSync, selectRecords } from "../src/sync.ts";

const MACBOOK = "05d8dedd-c925-4924-8db9-45f3e7452d34" as DeviceId;
const TOKEN = randomBytes(30).toString("base64url");
const CUTOFF = "2026-11-16T18:28:20Z";
const sha = (d: Uint8Array | string) => createHash("sha256").update(d).digest("hex");

let dir: string;
type Cert = { cert: string; key: string; pin: string };
let certA: Cert;
let certB: Cert;

async function makeCert(name: string): Promise<Cert> {
  const key = join(dir, `${name}.key`);
  const cert = join(dir, `${name}.pem`);
  const p = Bun.spawn(
    [
      "openssl",
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:prime256v1",
      "-nodes",
      "-keyout",
      key,
      "-out",
      cert,
      "-days",
      "1",
      "-subj",
      `/CN=${name}`,
      "-addext",
      "subjectAltName=IP:127.0.0.1",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=digitalSignature,keyCertSign",
    ],
    { stdout: "ignore", stderr: "ignore" },
  );
  if ((await p.exited) !== 0) throw new Error("openssl failed");
  const pem = await Bun.file(cert).text();
  return { cert: pem, key: await Bun.file(key).text(), pin: spkiPin(new X509Certificate(pem).raw) };
}

/// A float32 WAV of `frames` frames. Channel 0 is a sine; each other channel copies it, or holds
/// another sine when `differ` names it.
function makeWav(channels: number, frames: number, differ: number[] = []): Uint8Array {
  const block = channels * 4;
  const b = Buffer.alloc(44 + frames * block);
  b.write("RIFF", 0);
  b.writeUInt32LE(36 + frames * block, 4);
  b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(3, 20);
  b.writeUInt16LE(channels, 22);
  b.writeUInt32LE(48000, 24);
  b.writeUInt32LE(48000 * block, 28);
  b.writeUInt16LE(block, 32);
  b.writeUInt16LE(32, 34);
  b.write("data", 36);
  b.writeUInt32LE(frames * block, 40);
  for (let i = 0; i < frames; i++)
    for (let c = 0; c < channels; c++) {
      const f = differ.includes(c) ? 1000 : 440;
      b.writeFloatLE(0.4 * Math.sin((2 * Math.PI * f * i) / 48000), 44 + i * block + c * 4);
    }
  return new Uint8Array(b);
}

/// One archive record folder, shaped like ~/Transcripts/records/transcriber/<id>/.
async function makeRecord(
  archive: string,
  o: { timestamp: string; raw?: string; clean?: string; wav?: Uint8Array | null },
) {
  const id = randomUUID().toUpperCase();
  const d = join(archive, "records", "transcriber", id.toLowerCase());
  await mkdir(join(d, "source_versions"), { recursive: true });
  await mkdir(join(d, "artifacts"), { recursive: true });
  const version = {
    speech: { backend: "Deepgram", modelID: "nova-3", processingSeconds: 0.25 },
    textProcessing: { enabled: true, modelID: "qwen3-4b", status: "completed" },
    settings: {
      preferences: { language: "en", vocabulary: ["Codex"], proofreadingPrompt: "Fix it." },
    },
    detectedLanguage: "en",
  };
  const vText = JSON.stringify(version);
  await writeFile(join(d, "source_versions", `${sha(vText)}.json`), vText);
  const artifacts = [];
  if (o.wav) {
    await writeFile(join(d, "artifacts", `${sha(o.wav)}.wav`), o.wav);
    artifacts.push({
      kind: "original-audio",
      path: `artifacts/${sha(o.wav)}.wav`,
      sha256: sha(o.wav),
      bytes: o.wav.length,
    });
  }
  await writeFile(join(d, "raw.txt"), o.raw ?? "");
  await writeFile(join(d, "clean.txt"), o.clean ?? "");
  await writeFile(
    join(d, "metadata.json"),
    JSON.stringify({
      id,
      timestamp: o.timestamp,
      status: "completed",
      mode: "dictation",
      duration_seconds: 0.1,
      context: { app: "com.test", language: "en", device: { id: MACBOOK } },
      artifacts,
      source_versions: [{ path: `source_versions/${sha(vText)}.json` }],
    }),
  );
  return id.toLowerCase();
}

/// A hub like the deployed one: createHub over TLS on 127.0.0.1 with a temp database and share.
async function startHub(cert: Cert) {
  const root = await mkdtemp(join(dir, "hub-"));
  const share = join(root, "share");
  await Bun.write(join(share, SHARE_MARKER), "{}\n");
  const dbPath = join(root, "transcripts.sqlite");
  const init = new Database(dbPath);
  init.exec(await Bun.file(join(import.meta.dir, "../../../Hub/schema.sql")).text());
  init.close();
  const db = openStore(dbPath);
  const tokensPath = join(root, "tokens.json");
  await writeTokens(tokensPath, addToken({}, MACBOOK, TOKEN));
  const requests: string[] = [];
  const hub = createHub({
    db,
    shareRoot: share,
    tokensPath,
    clock: () => new Date("2026-11-16T20:00:00Z"), // outside the NAS window
    log: (l) => requests.push(l),
  });
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    tls: { cert: cert.cert, key: cert.key },
    maxRequestBodySize: 64 << 20,
    fetch: hub.fetch,
  });
  return {
    url: `https://127.0.0.1:${server.port}`,
    db,
    share,
    requests,
    stop: async () => {
      await server.stop(true);
      db.close();
    },
  };
}

const target = (addresses: string[], trust: Cert, pin = trust.pin): HubTarget => ({
  addresses,
  ca: trust.cert,
  pin,
  token: TOKEN,
});

let archive: string;
let store: ConfirmStore;
let logs: Record<string, unknown>[];

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), "hub-sync-test-"));
  certA = await makeCert("hub-a");
  certB = await makeCert("hub-b");
});
afterAll(async () => {
  await rm(dir, { recursive: true, force: true });
});
beforeEach(async () => {
  archive = await mkdtemp(join(dir, "archive-"));
  store = new ConfirmStore(join(archive, "state", "confirms.sqlite"));
  logs = [];
});

test("selection keeps records at or after --since without a stored confirm, oldest first", async () => {
  await makeRecord(archive, { timestamp: "2026-11-16T14:52:10Z", raw: "before" });
  const late = await makeRecord(archive, { timestamp: "2026-11-16T20:00:00Z", raw: "late" });
  const confirmed = await makeRecord(archive, { timestamp: "2026-11-16T19:00:00Z", raw: "done" });
  const atCutoff = await makeRecord(archive, { timestamp: CUTOFF, raw: "at" });
  store.put({
    recording_id: confirmed,
    flac_sha256: null,
    raw_sha256: null,
    clean_sha256: null,
    channels: null,
    confirmed_at: "2026-11-16T19:01:00Z",
    hub: "test",
  });
  const pick = (o: { since: string | null; only?: string }) =>
    selectRecords({
      archiveRoot: archive,
      confirmed: store.confirmedIds(),
      since: o.since,
      only: o.only ?? null,
      onError: () => {},
    }).then((s) => s.map((r) => r.recordingId));

  expect(await pick({ since: CUTOFF })).toEqual([atCutoff, late]);
  expect(await pick({ since: null })).toHaveLength(3);
  expect(await pick({ since: CUTOFF, only: late.toUpperCase() })).toEqual([late]);
  expect(await pick({ since: CUTOFF, only: confirmed })).toEqual([]);
});

test("the channel result names the extra channels that differ from channel 0", async () => {
  const same = makeWav(2, 3000);
  const differ = makeWav(4, 3000, [1]);
  await writeFile(join(archive, "same.wav"), same);
  await writeFile(join(archive, "differ.wav"), differ);

  const a = await scanWav(join(archive, "same.wav"));
  const b = await scanWav(join(archive, "differ.wav"));
  expect(a.channels).toEqual({ channels: 2, differing: [] });
  expect(b.channels).toEqual({ channels: 4, differing: [1] });
  expect(String(a.sha256)).toBe(sha(same));
  expect(String(b.sha256)).toBe(sha(differ));
});

test("a hub whose key does not match the pin gets no request", async () => {
  const hub = await startHub(certA);
  try {
    // Trusts the hub's certificate but holds another key's pin.
    const wrongPin = new HubClient(target([hub.url], certA, certB.pin));
    const e1 = await wrongPin.connect().catch((e: unknown) => e);
    expect(e1).toBeInstanceOf(StopRun);
    expect((e1 as StopRun).stop.kind).toBe("pin_refused");
    // Trusts and pins another certificate than the one the server holds.
    const wrongCert = new HubClient(target([hub.url], certB));
    expect(((await wrongCert.connect().catch((e: unknown) => e)) as StopRun).stop.kind).toBe(
      "pin_refused",
    );
    expect(hub.requests).toEqual([]);
    // The right pin still connects, and every request makes a new pinned handshake.
    const right = new HubClient(target([hub.url], certA));
    expect(await right.connect()).toBe(hub.url);
    expect(hub.requests).toHaveLength(1);
    expect(((await wrongPin.connect().catch((e: unknown) => e)) as StopRun).stop.kind).toBe(
      "pin_refused",
    );
    expect(hub.requests).toHaveLength(1);
  } finally {
    await hub.stop();
  }
});

test("an unreachable hub stops the run, and the next run sends the missed records once", async () => {
  const withAudio = await makeRecord(archive, {
    timestamp: "2026-11-16T19:00:00Z",
    raw: "raw words",
    clean: "Clean words.",
    wav: makeWav(2, 4800),
  });
  const noAudio = await makeRecord(archive, { timestamp: "2026-11-16T19:30:00Z", raw: "only raw" });
  const empty = await makeRecord(archive, {
    timestamp: "2026-11-16T19:45:00Z",
    wav: makeWav(1, 4800),
  });
  await makeRecord(archive, { timestamp: "2026-11-16T10:00:00Z", raw: "before the cut-off" });

  // A port that was just closed: nothing listens there.
  const closed = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("") });
  const deadUrl = `https://127.0.0.1:${closed.port}`;
  await closed.stop(true);

  const run = (t: HubTarget) =>
    runSync({
      archiveRoot: archive,
      store,
      target: t,
      since: CUTOFF,
      only: null,
      dryRun: false,
      log: (l) => logs.push(l),
    });

  const first = await run(target([deadUrl], certA));
  expect(first.stopped?.kind).toBe("unreachable");
  expect(first).toMatchObject({ selected: 3, confirmed: 0, left: 3 });
  expect(store.confirmedIds().size).toBe(0);

  const hub = await startHub(certA);
  try {
    // The dead address first, then the live one: the run falls through to the second address.
    const second = await run(target([deadUrl, hub.url], certA));
    expect(second).toMatchObject({
      selected: 3,
      confirmed: 3,
      failed: 0,
      left: 0,
      stopped: null,
      hub: hub.url,
    });
    expect([...store.confirmedIds()].sort()).toEqual([withAudio, noAudio, empty].sort());

    const rows = hub.db
      .query<{ recording_id: string; audio_sha256: string | null; t: number; c: number }, []>(
        "select r.recording_id, r.audio_sha256, (select count(*) from transcriptions t where t.recording_id = r.recording_id) t," +
          " (select count(*) from cleanups c where c.recording_id = r.recording_id) c from recordings r",
      )
      .all();
    const by = Object.fromEntries(rows.map((r) => [r.recording_id, r]));
    expect(by[withAudio]).toMatchObject({ t: 1, c: 1 });
    expect(by[noAudio]).toMatchObject({ t: 1, c: 0, audio_sha256: null });
    expect(by[empty]).toMatchObject({ t: 0, c: 0 });
    const flacSha = by[withAudio]!.audio_sha256!;
    const stored = new Uint8Array(
      await Bun.file(
        join(hub.share, "artifacts", flacSha.slice(0, 2), `${flacSha}.flac`),
      ).arrayBuffer(),
    );
    expect(sha(stored)).toBe(flacSha);
    const line = logs.find((l) => l.recording_id === withAudio && l.result === "confirmed");
    expect(line).toMatchObject({ flac_sha256: flacSha, channels: 2, differing_channels: [] });
    expect(JSON.stringify(logs)).not.toContain(TOKEN);

    const posts = hub.requests.length;
    const third = await run(target([hub.url], certA));
    expect(third).toMatchObject({ selected: 0, confirmed: 0, stopped: null });
    expect(hub.requests.length).toBe(posts);
    expect(await readdir(join(hub.share, "artifacts", flacSha.slice(0, 2)))).toEqual([
      `${flacSha}.flac`,
    ]);
  } finally {
    await hub.stop();
  }
});
