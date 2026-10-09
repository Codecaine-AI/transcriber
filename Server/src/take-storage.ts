// Fork: durable take files. Uploaded audio streams straight into private WAV
// staging files, so sealing is a rename instead of a copy, and an interrupted
// take can always be recovered from what was acknowledged.
import { constants } from "node:fs";
import { lstat, open, rename, rm, type FileHandle } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import type { AudioArtifact, AudioKind, AudioStreamFormat } from "./api.ts";
import { ServiceError } from "./errors.ts";
import { requireRegularDirectory } from "./storage.ts";

const HEADER_BYTES = 44;
const READ_ONLY = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK;
const READ_WRITE = constants.O_RDWR | constants.O_NOFOLLOW | constants.O_NONBLOCK;

/** The private staging name; old server versions neither read nor delete it. */
const stagingName = (kind: AudioKind) => `${kind}.wav.upload`;
const sealedName = (kind: AudioKind) => `${kind}.wav`;

/** The same IEEE-float WAV header the copying seal wrote. */
function wavHeader(format: AudioStreamFormat, dataBytes: number) {
  const header = Buffer.alloc(HEADER_BYTES);
  header.write("RIFF");
  header.writeUInt32LE(dataBytes + 36, 4);
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(3, 20);
  header.writeUInt16LE(format.channels, 22);
  header.writeUInt32LE(format.sampleRate, 24);
  header.writeUInt32LE(format.sampleRate * format.channels * 4, 28);
  header.writeUInt16LE(format.channels * 4, 32);
  header.writeUInt16LE(32, 34);
  header.write("data", 36);
  header.writeUInt32LE(dataBytes, 40);
  return header;
}

/** Accepts only headers this server writes; anything else is left untouched on disk. */
function headerFormat(header: Buffer): AudioStreamFormat | undefined {
  if (header.length !== HEADER_BYTES) return;
  const channels = header.readUInt16LE(22),
    sampleRate = header.readUInt32LE(24);
  if (
    header.toString("latin1", 0, 4) !== "RIFF" ||
    header.toString("latin1", 8, 16) !== "WAVEfmt " ||
    header.readUInt32LE(16) !== 16 ||
    header.readUInt16LE(20) !== 3 ||
    channels < 1 ||
    channels > 8 ||
    sampleRate < 8000 ||
    sampleRate > 192000 ||
    header.readUInt32LE(28) !== sampleRate * channels * 4 ||
    header.readUInt16LE(32) !== channels * 4 ||
    header.readUInt16LE(34) !== 32 ||
    header.toString("latin1", 36, 40) !== "data"
  )
    return;
  return { sampleRate, channels };
}

function artifact(kind: AudioKind, format: AudioStreamFormat, dataBytes: number): AudioArtifact {
  return {
    filename: sealedName(kind),
    sampleRate: format.sampleRate,
    channels: format.channels,
    frameCount: dataBytes / (format.channels * 4),
    byteCount: dataBytes + HEADER_BYTES,
    encoding: "pcm_f32le",
  };
}

async function writeFully(file: FileHandle, data: Buffer, position: number) {
  let written = 0;
  while (written < data.length) {
    const result = await file.write(data, written, data.length - written, position + written);
    if (!result.bytesWritten) throw new Error("Audio write failed.");
    written += result.bytesWritten;
  }
}

async function readHeader(file: FileHandle) {
  const header = Buffer.alloc(HEADER_BYTES);
  const { bytesRead } = await file.read(header, 0, HEADER_BYTES, 0);
  return header.subarray(0, bytesRead);
}

async function exists(path: string) {
  try {
    const info = await lstat(path);
    return info.isFile() && !info.isSymbolicLink();
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return false;
    throw error;
  }
}

/** Persists directory entries: renames and creations before anything that references them. */
export async function syncDirectory(path: string) {
  const directory = await open(
    path,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}

/**
 * Appends one chunk after `dataBytes` already-acknowledged bytes. The header is
 * rewritten to cover the new chunk and both reach disk in one sync before the
 * chunk is acknowledged, so the staging file is always a valid WAV of every
 * acknowledged frame. The first chunk also persists the new directory entries.
 */
export async function appendStagedAudio(
  directory: string,
  kind: AudioKind,
  format: AudioStreamFormat,
  dataBytes: number,
  data: Buffer,
) {
  const create = dataBytes === 0;
  const file = await open(
    join(directory, stagingName(kind)),
    constants.O_WRONLY |
      constants.O_NOFOLLOW |
      constants.O_NONBLOCK |
      (create ? constants.O_CREAT | constants.O_EXCL : 0),
    0o600,
  );
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size !== (create ? 0 : HEADER_BYTES + dataBytes))
      throw new ServiceError(500, "invalid_archive", "An audio upload changed unexpectedly.");
    await writeFully(file, data, HEADER_BYTES + dataBytes);
    await writeFully(file, wavHeader(format, dataBytes + data.length), 0);
    await file.sync();
  } finally {
    await file.close();
  }
  if (create) await Promise.all([syncDirectory(directory), syncDirectory(dirname(directory))]);
}

/** Reads an acknowledged chunk back so a repeated upload can be compared with it. */
export async function readStagedAudio(
  directory: string,
  kind: AudioKind,
  dataBytes: number,
  offset: number,
  count: number,
) {
  const file = await open(join(directory, stagingName(kind)), READ_ONLY);
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size !== HEADER_BYTES + dataBytes)
      throw new ServiceError(500, "invalid_archive", "An audio upload changed unexpectedly.");
    const replay = Buffer.alloc(count);
    const { bytesRead } = await file.read(replay, 0, count, HEADER_BYTES + offset);
    return replay.subarray(0, bytesRead);
  } finally {
    await file.close();
  }
}

/**
 * Seals a completely uploaded stream: the staging file already holds a synced,
 * correct header, so this verifies it and renames it into place. Callers sync
 * the directory once after sealing every stream and before saving metadata.
 */
export async function sealStagedAudio(
  directory: string,
  kind: AudioKind,
  format: AudioStreamFormat,
  dataBytes: number,
): Promise<AudioArtifact> {
  await requireRegularDirectory(directory);
  const staging = join(directory, stagingName(kind));
  const file = await open(staging, READ_WRITE);
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size !== HEADER_BYTES + dataBytes)
      throw new Error("Audio changed before sealing.");
    const expected = wavHeader(format, dataBytes);
    if (!(await readHeader(file)).equals(expected)) {
      await writeFully(file, expected, 0);
      await file.sync();
    }
  } finally {
    await file.close();
  }
  await rename(staging, join(directory, sealedName(kind)));
  return artifact(kind, format, dataBytes);
}

/** True when the sealed file a record references is present. */
export function sealedAudioExists(directory: string, kind: AudioKind) {
  return exists(join(directory, sealedName(kind)));
}

/**
 * Recovers whatever audio of one stream reached disk, without deleting anything.
 * A sealed file (left by a seal whose metadata commit failed) is adopted; a
 * staging file is trimmed to whole frames, its header patched to match, synced
 * and renamed into place. Returns undefined, leaving files untouched, when there
 * is no audio or the file is not one this server wrote.
 */
export async function recoverStagedAudio(
  directory: string,
  kind: AudioKind,
): Promise<AudioArtifact | undefined> {
  await requireRegularDirectory(directory);
  const sealed = join(directory, sealedName(kind)),
    staging = join(directory, stagingName(kind));
  const source = (await exists(sealed)) ? sealed : (await exists(staging)) ? staging : undefined;
  if (!source) return;
  const file = await open(source, READ_WRITE);
  let recovered: AudioArtifact;
  try {
    const info = await file.stat();
    const format = headerFormat(await readHeader(file));
    if (!info.isFile() || !format) return;
    const frameBytes = format.channels * 4;
    const dataBytes = Math.floor(Math.max(0, info.size - HEADER_BYTES) / frameBytes) * frameBytes;
    if (!dataBytes) return;
    // Only a torn partial frame is trimmed; every whole frame is kept.
    if (info.size !== HEADER_BYTES + dataBytes) await file.truncate(HEADER_BYTES + dataBytes);
    await writeFully(file, wavHeader(format, dataBytes), 0);
    await file.sync();
    recovered = artifact(kind, format, dataBytes);
  } finally {
    await file.close();
  }
  if (source === staging) await rename(staging, sealed);
  await syncDirectory(directory);
  return recovered;
}

/**
 * Atomically replaces several small private files at once: each is written,
 * synced and renamed concurrently, then one directory sync makes them durable
 * together. Callers commit metadata.json afterwards.
 */
export async function writePrivateFiles(directory: string, files: [string, string][]) {
  await requireRegularDirectory(directory);
  const results = await Promise.allSettled(
    files.map(async ([name, data]) => {
      const path = join(directory, name);
      try {
        const info = await lstat(path);
        if (!info.isFile() || info.isSymbolicLink())
          throw new ServiceError(
            500,
            "invalid_storage",
            "An archive artifact must be a regular file.",
          );
      } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
      }
      const temporary = join(directory, `.${basename(path)}.${randomUUID()}.partial`);
      const file = await open(
        temporary,
        constants.O_WRONLY |
          constants.O_CREAT |
          constants.O_EXCL |
          constants.O_NOFOLLOW |
          constants.O_NONBLOCK,
        0o600,
      );
      try {
        await file.writeFile(data);
        await file.sync();
        await file.close();
        await rename(temporary, path);
      } catch (error) {
        await file.close().catch(() => {});
        await rm(temporary, { force: true }).catch(() => {});
        throw error;
      }
    }),
  );
  const failure = results.find(
    (result): result is PromiseRejectedResult => result.status === "rejected",
  );
  if (failure) throw failure.reason as Error;
  await syncDirectory(directory);
}
