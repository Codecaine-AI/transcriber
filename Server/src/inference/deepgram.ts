import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/** "auth" and "rejected" are permanent for the request; "failed", "timeout", and "empty" are retryable. */
export type DeepgramFailureKind =
  "missingKey" | "offline" | "auth" | "rejected" | "timeout" | "failed" | "empty" | "cancelled";

export class DeepgramError extends Error {
  constructor(
    readonly kind: DeepgramFailureKind,
    message: string,
  ) {
    super(message);
    this.name = "DeepgramError";
  }
}

export interface DeepgramOptions {
  apiKey: string;
  language: string;
  keyterms: string[];
}

export interface DeepgramTranscript {
  text: string;
  language: string;
  audioSeconds: number;
  processingSeconds: number;
  modelID: "nova-3";
}

const HOST = "api.deepgram.com";
const MAX_KEYTERMS = 100;
const MAX_KEYTERM_CHARACTERS = 2000;
const CONNECT_TIMEOUT_MS = 5000;
const KEEP_ALIVE_MS = 4000;

function unquote(value: string) {
  const quote = value[0];
  return value.length >= 2 && (quote === '"' || quote === "'") && value.endsWith(quote)
    ? value.slice(1, -1)
    : value;
}

/** process.env.DEEPGRAM_API_KEY wins; otherwise read ~/.config/codecaine/env. Re-reads the file on every call (cheap; picks up key rotation). Returns undefined when absent. */
export async function deepgramApiKey(): Promise<string | undefined> {
  const environment = process.env.DEEPGRAM_API_KEY?.trim();
  if (environment) return environment;
  let contents: string;
  try {
    contents = await readFile(join(homedir(), ".config", "codecaine", "env"), "utf8");
  } catch {
    return;
  }
  let key: string | undefined;
  for (const raw of contents.split(/\r?\n/)) {
    const line = raw.trim().replace(/^export\s+/, "");
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 0 || line.slice(0, separator).trim() !== "DEEPGRAM_API_KEY") continue;
    key = unquote(line.slice(separator + 1).trim()).trim() || undefined;
  }
  return key;
}

function deepgramLanguage(language: string) {
  return language === "auto" || !language ? "en" : language;
}

function listenURL(protocol: "https" | "wss", options: DeepgramOptions) {
  const parameters = new URLSearchParams({
    model: "nova-3",
    language: deepgramLanguage(options.language),
    punctuate: "true",
    smart_format: "true",
  });
  if (protocol === "wss") {
    parameters.set("encoding", "linear16");
    parameters.set("sample_rate", "16000");
    parameters.set("channels", "1");
    parameters.set("interim_results", "false");
  }
  let count = 0;
  let characters = 0;
  for (const term of new Set(options.keyterms.map((value) => value.trim()))) {
    if (!term) continue;
    if (count >= MAX_KEYTERMS || characters + term.length > MAX_KEYTERM_CHARACTERS) break;
    parameters.append("keyterm", term);
    count += 1;
    characters += term.length;
  }
  return `${protocol}://${HOST}/v1/listen?${parameters}`;
}

function authorization(apiKey: string) {
  return { Authorization: `Token ${apiKey}` };
}

function elapsed(start: number) {
  return (performance.now() - start) / 1000;
}

function isAbort(error: unknown) {
  return (
    error instanceof DOMException && (error.name === "AbortError" || error.name === "TimeoutError")
  );
}

async function classifyConnectFailure(apiKey: string): Promise<DeepgramError> {
  try {
    const response = await fetch(`https://${HOST}/v1/projects`, {
      headers: authorization(apiKey),
      signal: AbortSignal.timeout(3000),
    });
    await response.body?.cancel();
    // 403 here can mean a key scoped away from /v1/projects, not a bad key.
    if (response.status === 401) return new DeepgramError("auth", "Deepgram rejected the API key.");
    return new DeepgramError("failed", "Deepgram refused the streaming connection.");
  } catch (error) {
    if (isAbort(error)) return new DeepgramError("timeout", "Deepgram did not respond in time.");
    return new DeepgramError("offline", "Deepgram is unreachable.");
  }
}

function float32ToLinear16(data: Uint8Array) {
  const frames = Math.floor(data.byteLength / 4);
  const source = new DataView(data.buffer, data.byteOffset, frames * 4);
  const output = new ArrayBuffer(frames * 2);
  const target = new DataView(output);
  for (let index = 0; index < frames; index += 1) {
    const sample = Math.max(-1, Math.min(1, source.getFloat32(index * 4, true) || 0));
    target.setInt16(index * 2, Math.round(sample < 0 ? sample * 0x8000 : sample * 0x7fff), true);
  }
  return output;
}

interface ResultsMessage {
  type: "Results";
  is_final?: boolean;
  duration?: number;
  channel?: {
    alternatives?: { transcript?: unknown }[];
    detected_language?: unknown;
    languages?: unknown[];
  };
}

interface MetadataMessage {
  type: "Metadata";
  duration?: number;
}

type LiveMessage = ResultsMessage | MetadataMessage | { type: "Error"; description?: unknown };

type BunWebSocket = new (url: string, options: Bun.WebSocketOptions) => WebSocket;

export class DeepgramLiveSession {
  /** Resolves with the classified DeepgramError on any failure (connect, mid-stream, finish, or abort's "cancelled") — lets the server start warming local Whisper early. Never rejects; stays pending after success. */
  readonly failed: Promise<DeepgramError>;

  private readonly socket: WebSocket;
  private readonly pending: ArrayBuffer[] = [];
  private readonly finals: string[] = [];
  private resolveFailed!: (error: DeepgramError) => void;
  private opened = false;
  private closed = false;
  private stopped = false;
  private failure?: DeepgramError;
  private resultSeconds = 0;
  private metadataSeconds?: number;
  private detectedLanguage?: string;
  private keepAlive?: ReturnType<typeof setInterval>;
  private connectTimer?: ReturnType<typeof setTimeout>;
  private finishTimer?: ReturnType<typeof setTimeout>;
  private finishing?: Promise<DeepgramTranscript>;
  private settle?: { resolve: () => void; reject: (error: DeepgramError) => void };

  private constructor(private readonly options: DeepgramOptions) {
    this.failed = new Promise((resolve) => {
      this.resolveFailed = resolve;
    });
    this.socket = new (WebSocket as unknown as BunWebSocket)(listenURL("wss", options), {
      headers: authorization(options.apiKey),
    });
    this.socket.binaryType = "arraybuffer";
    this.connectTimer = setTimeout(() => this.connectFailed(), CONNECT_TIMEOUT_MS);
    this.socket.addEventListener("open", () => this.handleOpen());
    this.socket.addEventListener("message", (event) => this.handleMessage(event.data));
    this.socket.addEventListener("error", () => {
      if (!this.opened) this.connectFailed();
    });
    this.socket.addEventListener("close", (event) => this.handleClose(event.code));
  }

  /** Starts connecting immediately; never throws. Audio sent before the socket opens is buffered. */
  static open(options: DeepgramOptions): DeepgramLiveSession {
    return new DeepgramLiveSession(options);
  }

  /** `data` is little-endian float32 mono 16 kHz samples. Converted to linear16 and sent. No-op after finish/abort. */
  send(data: Uint8Array) {
    if (this.stopped || this.finishing || this.closed || this.failure) return;
    const audio = float32ToLinear16(data);
    if (!audio.byteLength) return;
    if (this.opened) this.socket.send(audio);
    else this.pending.push(audio);
  }

  /** Flush (Finalize), CloseStream, and resolve with the concatenated final transcript. Rejects with DeepgramError. Idempotent. timeoutSeconds counts from the first call. */
  finish(timeoutSeconds = 15): Promise<DeepgramTranscript> {
    this.finishing ??= this.complete(timeoutSeconds);
    return this.finishing;
  }

  /** Close immediately; pending finish rejects with kind "cancelled". */
  abort() {
    if (this.stopped) return;
    this.fail(new DeepgramError("cancelled", "Deepgram transcription cancelled."));
  }

  private async complete(timeoutSeconds: number): Promise<DeepgramTranscript> {
    const start = performance.now();
    if (this.stopped && this.failure) throw this.failure;
    const done = new Promise<void>((resolve, reject) => {
      this.settle = { resolve, reject };
    });
    this.finishTimer = setTimeout(
      () => this.fail(new DeepgramError("timeout", "Deepgram did not finish in time.")),
      Math.max(0, timeoutSeconds) * 1000,
    );
    if (this.opened) this.closeStream();
    await done;
    return {
      text: this.finals.join(" ").trim(),
      language: this.detectedLanguage ?? deepgramLanguage(this.options.language),
      audioSeconds: this.metadataSeconds ?? this.resultSeconds,
      processingSeconds: elapsed(start),
      modelID: "nova-3",
    };
  }

  private handleOpen() {
    if (this.stopped || this.failure) return;
    this.opened = true;
    clearTimeout(this.connectTimer);
    for (const audio of this.pending.splice(0)) this.socket.send(audio);
    if (this.finishing) this.closeStream();
    else
      this.keepAlive = setInterval(() => {
        if (this.socket.readyState === WebSocket.OPEN)
          this.socket.send(JSON.stringify({ type: "KeepAlive" }));
      }, KEEP_ALIVE_MS);
  }

  private closeStream() {
    clearInterval(this.keepAlive);
    if (this.socket.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify({ type: "Finalize" }));
    this.socket.send(JSON.stringify({ type: "CloseStream" }));
  }

  private handleMessage(data: unknown) {
    if (typeof data !== "string") return;
    let message: LiveMessage;
    try {
      message = JSON.parse(data) as LiveMessage;
    } catch {
      return;
    }
    if (message.type === "Results") {
      if (!message.is_final) return;
      if (typeof message.duration === "number") this.resultSeconds += message.duration;
      const channel = message.channel;
      const transcript = channel?.alternatives?.[0]?.transcript;
      if (typeof transcript === "string" && transcript.trim()) this.finals.push(transcript.trim());
      const language = channel?.detected_language ?? channel?.languages?.[0];
      if (typeof language === "string" && language) this.detectedLanguage = language;
    } else if (message.type === "Metadata") {
      if (typeof message.duration === "number") this.metadataSeconds = message.duration;
      if (this.finishing) this.succeed();
    }
  }

  private handleClose(code: number) {
    this.closed = true;
    this.clearTimers();
    if (this.stopped) return;
    if (!this.opened) return this.connectFailed();
    if (this.finishing && code === 1000) return this.succeed();
    // The socket did open, so even an abnormal 1006 drop is retryable rather than offline.
    this.fail(
      new DeepgramError("failed", `Deepgram closed the stream unexpectedly (code ${code}).`),
    );
  }

  private connectFailed() {
    if (this.opened || this.stopped || this.failure) return;
    const placeholder = new DeepgramError("failed", "Deepgram connection failed.");
    this.failure = placeholder;
    this.pending.length = 0;
    clearTimeout(this.connectTimer);
    if (!this.closed) this.socket.close();
    void classifyConnectFailure(this.options.apiKey).then((error) => {
      if (this.failure !== placeholder) return;
      this.fail(error);
    });
  }

  private succeed() {
    if (this.stopped) return;
    this.stopped = true;
    this.clearTimers();
    if (!this.closed) this.socket.close(1000);
    this.settle?.resolve();
  }

  private fail(error: DeepgramError) {
    if (this.stopped) return;
    this.stopped = true;
    this.failure = error;
    this.pending.length = 0;
    this.clearTimers();
    this.resolveFailed(error);
    if (!this.closed) this.socket.close(1000);
    this.settle?.reject(error);
  }

  private clearTimers() {
    clearTimeout(this.connectTimer);
    clearTimeout(this.finishTimer);
    clearInterval(this.keepAlive);
  }
}

function chunk(view: DataView, offset: number) {
  return String.fromCharCode(
    view.getUint8(offset),
    view.getUint8(offset + 1),
    view.getUint8(offset + 2),
    view.getUint8(offset + 3),
  );
}

/** Rewrites an IEEE float32 WAV as 16-bit PCM; any other WAV is returned unchanged. */
function uploadableWAV(file: Uint8Array<ArrayBuffer>): {
  body: Uint8Array<ArrayBuffer>;
  seconds?: number;
} {
  const view = new DataView(file.buffer, file.byteOffset, file.byteLength);
  if (file.byteLength < 12 || chunk(view, 0) !== "RIFF" || chunk(view, 8) !== "WAVE")
    return { body: file };
  let format: { tag: number; channels: number; sampleRate: number; bits: number } | undefined;
  let offset = 12;
  while (offset + 8 <= file.byteLength) {
    const id = chunk(view, offset);
    const size = view.getUint32(offset + 4, true);
    const start = offset + 8;
    if (id === "fmt " && size >= 16 && start + 16 <= file.byteLength) {
      let tag = view.getUint16(start, true);
      if (tag === 0xfffe && size >= 26 && start + 26 <= file.byteLength)
        tag = view.getUint16(start + 24, true);
      format = {
        tag,
        channels: view.getUint16(start + 2, true),
        sampleRate: view.getUint32(start + 4, true),
        bits: view.getUint16(start + 14, true),
      };
    } else if (id === "data" && format) {
      const end = Math.min(file.byteLength, start + size);
      const seconds =
        format.sampleRate && format.channels && format.bits
          ? (end - start) / (format.sampleRate * format.channels * (format.bits / 8))
          : undefined;
      if (format.tag !== 3 || format.bits !== 32) return { body: file, seconds };
      const samples = new Uint8Array(float32ToLinear16(file.subarray(start, end)));
      const header = new DataView(new ArrayBuffer(44));
      const text = (at: number, value: string) => {
        for (let index = 0; index < value.length; index += 1)
          header.setUint8(at + index, value.charCodeAt(index));
      };
      text(0, "RIFF");
      header.setUint32(4, samples.byteLength + 36, true);
      text(8, "WAVEfmt ");
      header.setUint32(16, 16, true);
      header.setUint16(20, 1, true);
      header.setUint16(22, format.channels, true);
      header.setUint32(24, format.sampleRate, true);
      header.setUint32(28, format.sampleRate * format.channels * 2, true);
      header.setUint16(32, format.channels * 2, true);
      header.setUint16(34, 16, true);
      text(36, "data");
      header.setUint32(40, samples.byteLength, true);
      const body = new Uint8Array(44 + samples.byteLength);
      body.set(new Uint8Array(header.buffer), 0);
      body.set(samples, 44);
      return { body, seconds };
    }
    offset = start + size + (size % 2);
  }
  return { body: file };
}

interface PrerecordedResponse {
  metadata?: { duration?: unknown };
  results?: {
    channels?: {
      alternatives?: { transcript?: unknown }[];
      detected_language?: unknown;
    }[];
  };
}

/** Prerecorded fallback: POST the WAV file at `wavPath` to https://api.deepgram.com/v1/listen. */
export async function transcribeFile(
  wavPath: string,
  options: DeepgramOptions,
  timeoutSeconds = 30,
  signal?: AbortSignal,
): Promise<DeepgramTranscript> {
  if (!options.apiKey) throw new DeepgramError("missingKey", "No Deepgram API key is configured.");
  if (signal?.aborted) throw new DeepgramError("cancelled", "Deepgram transcription cancelled.");
  const start = performance.now();
  const upload = uploadableWAV(new Uint8Array(await readFile(wavPath)));
  const signals = [AbortSignal.timeout(Math.max(0, timeoutSeconds) * 1000)];
  if (signal) signals.push(signal);
  let response: Response;
  let payload: PrerecordedResponse;
  try {
    response = await fetch(listenURL("https", options), {
      method: "POST",
      headers: { ...authorization(options.apiKey), "Content-Type": "audio/wav" },
      body: upload.body,
      signal: AbortSignal.any(signals),
    });
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      throw new DeepgramError("auth", "Deepgram rejected the API key.");
    }
    // Bad request or out of credit: retrying the same upload cannot succeed.
    if (response.status === 400 || response.status === 402) {
      await response.body?.cancel();
      throw new DeepgramError(
        "rejected",
        `Deepgram rejected the request (HTTP ${response.status}).`,
      );
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new DeepgramError("failed", `Deepgram returned HTTP ${response.status}.`);
    }
    try {
      payload = (await response.json()) as PrerecordedResponse;
    } catch (error) {
      if (isAbort(error)) throw error;
      throw new DeepgramError("failed", "Deepgram returned an unreadable response.");
    }
  } catch (error) {
    if (error instanceof DeepgramError) throw error;
    if (signal?.aborted) throw new DeepgramError("cancelled", "Deepgram transcription cancelled.");
    if (isAbort(error)) throw new DeepgramError("timeout", "Deepgram did not respond in time.");
    throw new DeepgramError("offline", "Deepgram is unreachable.");
  }
  const channel = payload.results?.channels?.[0];
  const transcript = channel?.alternatives?.[0]?.transcript;
  if (typeof transcript !== "string")
    throw new DeepgramError("empty", "Deepgram returned no transcript.");
  const duration = payload.metadata?.duration;
  const language = channel?.detected_language;
  return {
    text: transcript.trim(),
    language:
      typeof language === "string" && language ? language : deepgramLanguage(options.language),
    audioSeconds: typeof duration === "number" ? duration : (upload.seconds ?? 0),
    processingSeconds: elapsed(start),
    modelID: "nova-3",
  };
}
