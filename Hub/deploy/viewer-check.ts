// Checks of the viewer API (src/viewer.ts), run on services-01 against a copy of the database:
//   bun deploy/viewer-check.ts <database> <share>
// It starts the viewer on free loopback ports: one with the real clock and two with fixed clocks
// (11:00 and 12:01 UTC). It only reads the database (a readonly handle) and the share. For the
// link refusals it builds a small fake share in a temp folder, with links to one real FLAC. It
// checks the method refusals, encoded ../ paths, bad and unknown shas, the NAS window, Range reads,
// filters, and that search equals /v1/search (the hub handler, called in this process) for 5 queries.
// Run it outside 10:57 to 12:00 UTC: it reads the share. It prints one JSON line per check and
// exits 1 when a check fails.
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, open, rm, symlink, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHub } from "../src/hub.ts";
import { artifactPath, type Sha256 } from "../src/record.ts";
import { SHARE_MARKER, windowWait } from "../src/share.ts";
import { createViewer, openViewerDb } from "../src/viewer.ts";

const [dbPath, shareRoot] = process.argv.slice(2);
if (!dbPath || !shareRoot) {
  console.error("usage: bun deploy/viewer-check.ts <database> <share>");
  process.exit(2);
}
if (windowWait(new Date()) > 0) {
  console.error("it is 10:57 to 12:00 UTC, the NAS window: run the check after 12:00 UTC");
  process.exit(1);
}

const QUERIES = ["the", "transcriber", "cursor agent", "let's go", "pull request review"];
let failed = 0;
function report(check: string, pass: boolean, evidence: unknown) {
  if (!pass) failed++;
  console.log(JSON.stringify({ check, pass, evidence }));
}

const sha = (d: Uint8Array) => createHash("sha256").update(d).digest("hex");
const db = openViewerDb(dbPath);
const temp = await mkdtemp(join(tmpdir(), "viewer-check-"));
const servers: ReturnType<typeof Bun.serve>[] = [];
const quiet = () => {};

function serve(shareRoot: string, clock?: () => Date) {
  const viewer = createViewer({
    db,
    shareRoot,
    staticRoot: join(import.meta.dir, "../viewer"),
    nasStatusPath: join(temp, "nas-status.json"),
    clock,
    log: quiet,
  });
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: viewer.fetch });
  servers.push(server);
  return `http://127.0.0.1:${server.port}`;
}

/// A request sent as raw bytes, so no client parser normalizes the path. Returns the status code.
function rawStatus(base: string, path: string): Promise<number> {
  const { hostname, port } = new URL(base);
  return new Promise((resolve, reject) => {
    const socket = connect(Number(port), hostname, () =>
      socket.write(`GET ${path} HTTP/1.1\r\nHost: ${hostname}\r\nConnection: close\r\n\r\n`),
    );
    let text = "";
    socket.setEncoding("latin1");
    socket.on("data", (d: string) => (text += d));
    socket.on("end", () => resolve(Number(/^HTTP\/1\.1 (\d{3})/.exec(text)?.[1] ?? 0)));
    socket.on("error", reject);
    socket.setTimeout(10_000, () => socket.destroy(new Error("timeout")));
  });
}

const getJson = async (url: string) => {
  const res = await fetch(url);
  return { res, body: (await res.json()) as Record<string, unknown> };
};

try {
  const base = serve(shareRoot);
  const at11 = serve(shareRoot, () => new Date("2026-11-18T11:00:00Z"));
  const at1201 = serve(shareRoot, () => new Date("2026-11-18T12:01:00Z"));

  // A FLAC that has an audio row and a file on the share.
  const candidates = db
    .query<{ sha256: string; bytes: number }, []>(
      "select sha256, bytes from audio where bytes > 8192 order by bytes limit 20",
    )
    .all();
  let flac: { sha: Sha256; bytes: Uint8Array } | null = null;
  for (const c of candidates) {
    const bytes = await Bun.file(join(shareRoot, artifactPath(c.sha256 as Sha256)))
      .bytes()
      .catch(() => null);
    if (bytes && sha(bytes) === c.sha256) {
      flac = { sha: c.sha256 as Sha256, bytes };
      break;
    }
  }
  report("a FLAC with an audio row is on the share", flac !== null, flac?.sha ?? null);
  const audioPath = `/audio/${flac?.sha ?? "0".repeat(64)}.flac`;

  // The database handle refuses writes.
  let writeError = "";
  try {
    db.exec("create table viewer_check_probe(a)");
  } catch (error) {
    writeError = error instanceof Error ? error.message : String(error);
  }
  report("the database handle refuses a write", writeError !== "", writeError);

  // Only GET and HEAD.
  for (const method of ["POST", "PUT", "DELETE", "PATCH"])
    for (const path of ["/", "/api/records", audioPath, "/v1/records"]) {
      const res = await fetch(base + path, { method, body: method === "DELETE" ? null : "{}" });
      report(`${method} ${path.slice(0, 20)} gets 405`, res.status === 405, res.status);
    }
  const v1 = await fetch(`${base}/v1/search?q=the`);
  report("GET /v1/search is not a viewer route", v1.status === 404, v1.status);

  // Headers on every kind of response.
  for (const path of ["/api/records", "/api/records/nope", "/api/insights", audioPath, "/x"]) {
    const res = await fetch(base + path, { headers: { Range: "bytes=0-9" } });
    await res.arrayBuffer();
    const ok =
      res.headers.get("cache-control") === "no-store" &&
      res.headers.get("content-security-policy") === "default-src 'self'";
    report(`headers no-store and CSP on ${path.slice(0, 20)}`, ok, res.status);
  }

  // Paths that try to leave artifacts/.
  for (const path of [
    "/audio/..%2F..%2Fdb%2Ftranscripts.flac",
    "/audio/%2e%2e%2f%2e%2e%2f.transcriber-hub-share",
    "/audio/%2e%2e/%2e%2e/etc/passwd",
    "/audio/../../etc/passwd",
    `/audio/${flac?.sha.slice(0, 2)}%2F${flac?.sha}.flac`,
    `/audio/${flac?.sha}.flac%2F..%2F..%2F.transcriber-hub-share`,
    `/audio/..%252f${flac?.sha}.flac`,
  ]) {
    const status = await rawStatus(base, path);
    report(`traversal ${path.slice(0, 48)} is refused`, status === 400 || status === 404, status);
  }

  // Bad and unknown shas.
  for (const [name, path, want] of [
    ["a short sha", "/audio/abc123.flac", 400],
    ["an uppercase sha", `/audio/${(flac?.sha ?? "a".repeat(64)).toUpperCase()}.flac`, 400],
    ["a sha with no audio row", `/audio/${randomBytes(32).toString("hex")}.flac`, 404],
  ] as const) {
    const res = await fetch(base + path);
    const body = await res.text();
    report(`${name} is refused`, res.status === want, { status: res.status, body });
  }

  // The NAS window, with fixed clocks. Text pages still load in the window.
  const inWindow = await fetch(at11 + audioPath);
  const inBody = (await inWindow.json()) as { error?: string };
  report(
    "audio at 11:00 UTC gets 503 nas_window",
    inWindow.status === 503 && inBody.error === "nas_window",
    {
      status: inWindow.status,
      error: inBody.error,
      retry_after: inWindow.headers.get("retry-after"),
    },
  );
  const textInWindow = await fetch(`${at11}/api/records`);
  await textInWindow.arrayBuffer();
  report("records at 11:00 UTC get 200", textInWindow.status === 200, textInWindow.status);
  const after = await fetch(at1201 + audioPath);
  const afterBytes = new Uint8Array(await after.arrayBuffer());
  report(
    "audio at 12:01 UTC gets 200 with the whole file",
    after.status === 200 && flac !== null && sha(afterBytes) === flac.sha,
    {
      status: after.status,
      bytes: afterBytes.length,
    },
  );

  // Range reads.
  if (flac) {
    const size = flac.bytes.length;
    for (const [header, start, end] of [
      ["bytes=100-1099", 100, 1099],
      ["bytes=-500", size - 500, size - 1],
      [`bytes=${size - 10}-`, size - 10, size - 1],
      [`bytes=4000-${size + 999}`, 4000, size - 1],
    ] as const) {
      const res = await fetch(base + audioPath, { headers: { Range: header } });
      const got = new Uint8Array(await res.arrayBuffer());
      const want = flac.bytes.subarray(start, end + 1);
      report(
        `Range ${header} gets 206 with the right bytes`,
        res.status === 206 &&
          res.headers.get("content-range") === `bytes ${start}-${end}/${size}` &&
          sha(got) === sha(want),
        { status: res.status, content_range: res.headers.get("content-range"), bytes: got.length },
      );
    }
    const beyond = await fetch(base + audioPath, { headers: { Range: `bytes=${size}-` } });
    await beyond.arrayBuffer();
    report("a Range past the end gets 416", beyond.status === 416, {
      status: beyond.status,
      content_range: beyond.headers.get("content-range"),
    });
    const head = await fetch(base + audioPath, { method: "HEAD" });
    report(
      "HEAD on audio gets 200 with the size",
      head.status === 200 && head.headers.get("content-length") === String(size),
      {
        status: head.status,
        length: head.headers.get("content-length"),
      },
    );
  }

  // Links: a fake share in a temp folder whose FLAC, or whose artifacts folder, is a link.
  if (flac) {
    const real = join(shareRoot, artifactPath(flac.sha));
    const fileLink = join(temp, "share-file-link");
    await mkdir(join(fileLink, "artifacts", flac.sha.slice(0, 2)), { recursive: true });
    await writeFile(join(fileLink, SHARE_MARKER), "");
    await symlink(real, join(fileLink, artifactPath(flac.sha)));
    const dirLink = join(temp, "share-dir-link");
    await mkdir(join(dirLink, "artifacts"), { recursive: true });
    await writeFile(join(dirLink, SHARE_MARKER), "");
    await symlink(
      join(shareRoot, "artifacts", flac.sha.slice(0, 2)),
      join(dirLink, "artifacts", flac.sha.slice(0, 2)),
    );
    for (const [name, root] of [
      ["a FLAC that is a link", fileLink],
      ["a folder that is a link", dirLink],
    ]) {
      const res = await fetch(serve(root!) + audioPath);
      const body = await res.text();
      report(`${name} is refused`, res.status === 403, {
        status: res.status,
        body: body.slice(0, 120),
      });
    }
    const noMarker = join(temp, "share-no-marker");
    await mkdir(noMarker);
    const res = await fetch(serve(noMarker) + audioPath);
    await res.arrayBuffer();
    report("a share with no marker gets 503", res.status === 503, res.status);
  }

  // The list, the filters and one record.
  const live = db.query<{ n: number }, []>("select count(*) as n from recordings").get()!.n;
  const list = await getJson(`${base}/api/records`);
  const items = list.body.items as { recording_id: string; has_audio: boolean }[];
  const newest = db
    .query<{ recording_id: string }, []>(
      "select recording_id from recordings order by recorded_at desc, recording_id limit 20",
    )
    .all()
    .map((r) => r.recording_id);
  report("the list count equals the recordings count", list.body.total === live, {
    total: list.body.total,
    live,
  });
  report(
    "the first page is the 20 newest",
    JSON.stringify(items.map((i) => i.recording_id)) === JSON.stringify(newest),
    items.length,
  );
  const withAudio = db
    .query<{ n: number }, []>("select count(*) as n from recordings where audio_sha256 is not null")
    .get()!.n;
  const audioList = await getJson(`${base}/api/records?audio=1&page=2`);
  const audioItems = audioList.body.items as { has_audio: boolean }[];
  report(
    "audio=1 filters before the page cut",
    audioList.body.total === withAudio &&
      audioItems.length === 20 &&
      audioItems.every((i) => i.has_audio),
    {
      total: audioList.body.total,
      live: withAudio,
    },
  );
  const wispr = await getJson(
    `${base}/api/records?source=wispr-flow&from=2025-01-01&to=2025-12-31`,
  );
  report(
    "source and dates filter",
    wispr.res.status === 200 && typeof wispr.body.total === "number",
    wispr.body.total,
  );
  for (const query of [
    "source=foo",
    "audio=2",
    "mode=zzz",
    "from=2026-13-01",
    "to=yesterday",
    "page=0",
    "color=red",
  ]) {
    const res = await fetch(`${base}/api/records?${query}`);
    await res.arrayBuffer();
    report(`filter ${query} gets 400`, res.status === 400, res.status);
  }
  const one = await getJson(`${base}/api/records/${newest[0]}`);
  report(
    "a record has its recording and texts",
    one.res.status === 200 && Array.isArray(one.body.transcriptions),
    {
      status: one.res.status,
      transcriptions: (one.body.transcriptions as unknown[] | undefined)?.length,
      cleanups: (one.body.cleanups as unknown[] | undefined)?.length,
    },
  );
  const none = await fetch(`${base}/api/records/${randomUUID()}`);
  await none.arrayBuffer();
  report("an id with no row gets 404", none.status === 404, none.status);

  // Search equals /v1/search, called on the hub handler with a temp token.
  const token = randomBytes(32).toString("hex");
  await writeFile(
    join(temp, "tokens.json"),
    JSON.stringify({ [sha(new TextEncoder().encode(token))]: "viewer-check" }),
    { mode: 0o600 },
  );
  const hub = createHub({
    db,
    shareRoot: join(temp, "no-share"),
    tokensPath: join(temp, "tokens.json"),
    log: quiet,
  });
  for (const q of QUERIES) {
    const v1Res = await hub.fetch(
      new Request(`https://hub/v1/search?q=${encodeURIComponent(q)}`, {
        headers: { Authorization: `Bearer ${token}` },
      }),
    );
    const v1Body = (await v1Res.json()) as { results: { recording_id: string; score: number }[] };
    const view = await getJson(`${base}/api/records?q=${encodeURIComponent(q)}`);
    const viewItems = view.body.items as {
      recording_id: string;
      score: number;
      snippet: { marks: unknown[] } | null;
    }[];
    const same =
      v1Res.status === 200 &&
      JSON.stringify(v1Body.results.map((r) => [r.recording_id, r.score])) ===
        JSON.stringify(viewItems.map((r) => [r.recording_id, r.score]));
    report(`search "${q}" equals /v1/search`, same && viewItems.length > 0, {
      results: viewItems.length,
      marked: viewItems.filter((i) => (i.snippet?.marks.length ?? 0) > 0).length,
    });
  }

  // Insights, NAS and the static files.
  const ins = await getJson(`${base}/api/insights`);
  report("insights answer", ins.res.status === 200, {
    words_per_minute: (ins.body.words_per_minute as { value: unknown }).value,
    total_words: (ins.body.total_words as { value: unknown }).value,
    takes: ins.body.takes,
    apps: (ins.body.apps as { rows: unknown[] }).rows.slice(0, 3),
  });
  const nasMissing = await getJson(`${base}/api/nas`);
  report(
    "nas without a status file says not yet",
    nasMissing.res.status === 200 && nasMissing.body.reason === "not_yet",
    nasMissing.body,
  );
  const status = await open(join(temp, "nas-status.json"), "wx", 0o600);
  await status.writeFile(JSON.stringify({ checked_at: "2026-11-18T13:20:00Z", shares: [] }));
  await status.close();
  const nas = await getJson(`${base}/api/nas`);
  report(
    "nas returns the status file",
    nas.res.status === 200 && nas.body.available === true,
    nas.body.status,
  );
  for (const path of ["/src/main.ts", "/viewer/index.html", "/..%2Fsrc%2Fmain.ts", "/app.js.map"]) {
    const status = await rawStatus(base, path);
    report(`static ${path} is refused`, status === 404, status);
  }
} catch (error) {
  report("the check ran to the end", false, error instanceof Error ? error.message : String(error));
} finally {
  for (const s of servers) await s.stop(true);
  db.close();
  await rm(temp, { recursive: true, force: true });
}
console.log(JSON.stringify({ done: true, failed }));
process.exit(failed ? 1 : 0);
