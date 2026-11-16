// The transcripts share: the only place the hub reads or writes audio. Every read and write first
// checks the NAS window and the share marker, so a request that runs into 10:57 UTC stops at its
// next share step, and a bare mount point (the share not mounted) is never written.
import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { mkdir, open, rename, rm, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { HttpError } from "./errors.ts";
import { artifactPath, type Sha256 } from "./record.ts";

/// The NAS window: the daily NAS job (11:15 UTC) owns the NAS from 10:57 until 12:00 UTC.
const WINDOW_START = 10 * 60 + 57;
const WINDOW_END = 12 * 60;

export type Clock = () => Date;

/// Seconds until the window ends, or 0 when the window is open.
export function windowWait(now: Date): number {
  const minute = now.getUTCHours() * 60 + now.getUTCMinutes();
  if (minute < WINDOW_START || minute >= WINDOW_END) return 0;
  const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 12);
  return Math.max(1, Math.ceil((end - now.getTime()) / 1000));
}

export function assertWindowOpen(now: Date) {
  const wait = windowWait(now);
  if (wait > 0)
    throw new HttpError(503, "nas_window", "the NAS is busy from 10:57 to 12:00 UTC", {
      "Retry-After": String(wait),
    });
}

/// A file at the share root that exists only on the mounted share, never in the bare mount point.
export const SHARE_MARKER = ".transcriber-hub-share";

export type Faults = { afterFileWrite?: (sha: Sha256) => void };

export class Share {
  constructor(
    private readonly root: string,
    private readonly clock: Clock,
    private readonly faults: Faults = {},
  ) {}

  private async guard() {
    assertWindowOpen(this.clock());
    try {
      await stat(join(this.root, SHARE_MARKER));
    } catch {
      throw new HttpError(503, "share_unavailable", "the transcripts share is not mounted");
    }
  }

  /// SHA-256 of the file at a share path, or null when there is no file.
  async hash(relative: string): Promise<Sha256 | null> {
    await this.guard();
    let file;
    try {
      file = await open(join(this.root, relative), constants.O_RDONLY | constants.O_NOFOLLOW);
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") return null;
      throw error;
    }
    try {
      const h = createHash("sha256");
      const buffer = new Uint8Array(1 << 20);
      for (;;) {
        const { bytesRead } = await file.read(buffer, 0, buffer.length, null);
        if (bytesRead === 0) break;
        h.update(buffer.subarray(0, bytesRead));
      }
      return h.digest("hex") as Sha256;
    } finally {
      await file.close();
    }
  }

  /// Put the FLAC at artifacts/<2 hex>/<sha>.flac through a temp file and a rename, then read it
  /// back. A file that already holds these bytes is kept as it is. Returns whether it wrote.
  async putFlac(sha: Sha256, flac: Uint8Array): Promise<{ wrote: boolean }> {
    const relative = artifactPath(sha);
    if ((await this.hash(relative)) === sha) return { wrote: false };
    const final = join(this.root, relative);
    await this.guard();
    await mkdir(dirname(final), { recursive: true, mode: 0o700 });
    // A temp name that a crashed post leaves behind is recognizable: .<sha>.flac.<random>.partial
    const temp = join(dirname(final), `.${sha}.flac.${randomBytes(6).toString("hex")}.partial`);
    await this.guard();
    const file = await open(temp, "wx", 0o600);
    try {
      await file.writeFile(flac);
      await file.sync();
    } finally {
      await file.close();
    }
    await this.guard();
    await rename(temp, final);
    this.faults.afterFileWrite?.(sha);
    const back = await this.hash(relative);
    if (back !== sha) {
      await this.guard();
      await rm(final, { force: true });
      throw new HttpError(
        502,
        "readback_mismatch",
        "the FLAC read back from the share holds other bytes",
      );
    }
    return { wrote: true };
  }
}
