// A failed hub sync run sends its error to GlitchTip and keeps exit 1, whether the DSN is there or not.
import { afterEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const MAIN = join(import.meta.dir, "..", "src", "main.ts");
const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

// A run with an empty config folder fails in loadTarget, before it reads or sends a record.
async function failedRun(env: Record<string, string>, envFile?: string) {
  const home = mkdtempSync(join(tmpdir(), "hub-sync-errors-"));
  dirs.push(home);
  mkdirSync(join(home, "config"));
  if (envFile !== undefined) {
    mkdirSync(join(home, "workspace"));
    writeFileSync(join(home, "workspace", ".env"), envFile, { mode: 0o600 });
  }
  const log = join(home, "sync.log");
  const { GLITCHTIP_DSN_TRANSCRIBER_HUB_SYNC: _unset, ...parent } = process.env;
  const p = Bun.spawn(
    [
      "bun",
      MAIN,
      "--config",
      join(home, "config"),
      "--state",
      join(home, "confirms.sqlite"),
      "--log",
      log,
    ],
    {
      env: { ...parent, HOME: home, ...env },
      stdout: "ignore",
      stderr: "ignore",
    },
  );
  return { code: await p.exited, log: readFileSync(log, "utf8") };
}

async function withGlitchTip(body: (dsn: string, bodies: string[]) => Promise<void>) {
  const bodies: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (r) => {
      bodies.push(`${new URL(r.url).pathname} ${await r.text()}`);
      return Response.json({ id: "1" });
    },
  });
  try {
    await body(`http://k@127.0.0.1:${server.port}/6`, bodies);
  } finally {
    await server.stop(true);
  }
}

describe("a failed run", () => {
  it.each([
    [
      "the environment",
      (dsn: string) => ({ env: { GLITCHTIP_DSN_TRANSCRIBER_HUB_SYNC: dsn }, file: undefined }),
    ],
    [
      "~/workspace/.env",
      (dsn: string) => ({ env: {}, file: `OTHER=1\nGLITCHTIP_DSN_TRANSCRIBER_HUB_SYNC=${dsn}\n` }),
    ],
  ])("sends its error with the DSN from %s, and exits 1", async (_where, setup) => {
    await withGlitchTip(async (dsn, bodies) => {
      const { env, file } = setup(dsn);
      const r = await failedRun(env, file);
      expect(r.code).toBe(1);
      expect(bodies).toHaveLength(1);
      expect(bodies[0]).toStartWith("/api/6/envelope/ ");
      expect(bodies[0]).toContain('"handler":"run"');
    });
  });

  it("exits 1 with no DSN", async () => {
    const r = await failedRun({});
    expect(r.code).toBe(1);
    expect(r.log).toContain(
      "errors: off, no GLITCHTIP_DSN_TRANSCRIBER_HUB_SYNC in the environment",
    );
  });
});
