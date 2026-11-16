// The 30-day local delete, as a dry run only. It lists the archive records that the delete gate
// would let go, and why each other record stays. It never deletes, moves or changes a file: there
// is no delete in this client. A record is deletable only when all of these hold:
//   - its recorded_at is more than 30 days old
//   - it has a stored confirm, and its texts and audio presence still match that confirm
//   - the hub's reconfirm of the stored hashes is ok (the hub hashes the FLAC on the share again)
//   - its channel result is not "differs" (the mono FLAC drops extra channels with other audio)
import { readRecord, recordDirs } from "./archive.ts";
import type { ConfirmStore } from "./confirms.ts";
import { HubClient, RecordRefused, StopRun, type HubTarget, type Stop } from "./hub-client.ts";
import { assertClientWindow, message } from "./sync.ts";

export const REASONS = [
  "unreadable", // metadata.json or a text file cannot be read
  "no_time", // a Wispr Flow row without a timestamp: its age is unknown
  "too_new",
  "not_confirmed",
  "local_changed", // the record's texts or audio differ from what was confirmed
  "reconfirm_failed",
  "channels_differ",
  "deletable",
] as const;
export type Reason = (typeof REASONS)[number];

export type DryRunEntry = {
  recording_id: string | null;
  dir: string;
  recorded_at: string | null;
  reason: Reason;
  detail?: unknown;
};

export type DryRunResult = {
  cutoff: string;
  counts: Record<Reason, number>;
  unchecked: number; // records the run did not reach because it stopped
  stopped: Stop | null;
  hub: string | null;
  entries: DryRunEntry[];
};

export const DAY_MS = 24 * 60 * 60 * 1000;

export async function deleteDryRun(opts: {
  archiveRoot: string;
  store: ConfirmStore;
  target: HubTarget;
  days?: number;
  now?: () => Date;
}): Promise<DryRunResult> {
  const now = opts.now ?? (() => new Date());
  const cutoff = new Date(now().getTime() - (opts.days ?? 30) * DAY_MS).toISOString();
  const dirs = await recordDirs(opts.archiveRoot);
  const counts = Object.fromEntries(REASONS.map((r) => [r, 0])) as Record<Reason, number>;
  const result: DryRunResult = {
    cutoff,
    counts,
    unchecked: 0,
    stopped: null,
    hub: null,
    entries: [],
  };
  const hub = new HubClient(opts.target);
  const add = (e: DryRunEntry) => {
    counts[e.reason]++;
    result.entries.push(e);
  };

  for (const [i, dir] of dirs.entries()) {
    let record;
    try {
      record = await readRecord(dir);
    } catch (error) {
      add({
        recording_id: null,
        dir,
        recorded_at: null,
        reason: "unreadable",
        detail: message(error),
      });
      continue;
    }
    const base = { recording_id: record.recordingId, dir, recorded_at: record.recordedAt };
    if (record.recordedAt === null) {
      add({ ...base, reason: "no_time" });
      continue;
    }
    if (record.recordedAt >= cutoff) {
      add({ ...base, reason: "too_new" });
      continue;
    }
    const confirm = opts.store.get(record.recordingId);
    if (!confirm) {
      add({ ...base, reason: "not_confirmed" });
      continue;
    }
    const changed = [
      ["raw", confirm.raw_sha256, record.textSha256.raw],
      ["clean", confirm.clean_sha256, record.textSha256.clean],
      ["audio", confirm.flac_sha256 !== null, record.sourceWav !== null],
    ].flatMap(([field, confirmed, local]) => (confirmed === local ? [] : [field]));
    if (changed.length) {
      add({ ...base, reason: "local_changed", detail: changed });
      continue;
    }
    let reply: unknown;
    try {
      assertClientWindow(now());
      result.hub ??= await hub.connect();
      reply = await hub.reconfirm(record.recordingId, {
        flac_sha256: confirm.flac_sha256,
        text_sha256: { raw: confirm.raw_sha256, clean: confirm.clean_sha256 },
      });
    } catch (error) {
      if (error instanceof StopRun) {
        result.stopped = error.stop;
        result.unchecked = dirs.length - i;
        break;
      }
      if (!(error instanceof RecordRefused)) throw error;
      add({
        ...base,
        reason: "reconfirm_failed",
        detail: { status: error.status, code: error.code },
      });
      continue;
    }
    const ok =
      typeof reply === "object" && reply !== null && (reply as { ok?: unknown }).ok === true;
    if (!ok) {
      add({ ...base, reason: "reconfirm_failed", detail: reply });
      continue;
    }
    if (confirm.channels?.differing.length) {
      add({ ...base, reason: "channels_differ", detail: confirm.channels });
      continue;
    }
    add({ ...base, reason: "deletable" });
  }
  return result;
}
