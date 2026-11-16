import { expect, test } from "bun:test";
import { cleanupId, NS, pythonJson, stamp, transcriptionId } from "../src/ids.ts";

// Three rows of the live import on services-01, read from a .backup copy of transcripts.sqlite
// (transcripts.pre-hub.sqlite, 2026-11-16). Only keys, names and times, no text.
const LIVE_ROWS = [
  {
    recording_id: "00211142-b93f-41fa-b9b6-850ce5977856",
    provider: "whisper.cpp/Metal",
    model: "whisper-large-v3-turbo",
    created_at: "2026-09-24T15:04:16.000Z",
    transcription_id: "ebd546a8-dcfb-5e0c-89e1-fde4e9a21357",
    cleanup_id: "d061a6b4-e111-57e3-bb9d-9be4a6d7cdf5",
  },
  {
    recording_id: "fffce2c1-1c21-478c-b61d-89c506a98080",
    provider: "Deepgram",
    model: "nova-3",
    created_at: "2026-10-14T21:01:04.000Z",
    transcription_id: "fe66e2e6-eb52-5a06-8131-b758028a4023",
    cleanup_id: "30ac0212-9658-5bae-bb05-bc5c0bb3f939",
  },
  {
    recording_id: "05677dca-457c-4878-9ae3-e6eb1c33a159",
    provider: "Wispr Flow",
    model: "unknown",
    created_at: "2025-03-11T23:17:47.434Z",
    transcription_id: "4ccae613-763b-518f-b682-f4baef546eb2",
    cleanup_id: "81226713-109f-5b8e-8ae1-c60eecd74d1d",
  },
];

test("the namespace is uuid5(NAMESPACE_URL, the v1 URL)", () => {
  // python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "https://transcripts.lascari.internal/ns/v1"))'
  expect(NS).toBe("5783f8e1-37d9-523a-9d37-74978d78fa06");
});

test.each(LIVE_ROWS)("reproduces the live IDs of $recording_id", (row) => {
  const tid = transcriptionId(row.recording_id, row.provider, row.model, row.created_at);
  expect(tid).toBe(row.transcription_id);
  expect(cleanupId(tid)).toBe(row.cleanup_id);
});

test("stamp normalizes the archive and Wispr Flow time forms as importer.py does", () => {
  expect(stamp("2026-09-24T15:04:16Z")).toBe("2026-09-24T15:04:16.000Z");
  expect(stamp("2025-03-11 23:17:47.434 +00:00")).toBe("2025-03-11T23:17:47.434Z");
  expect(stamp("2026-03-01T15:33:44.168-05:00")).toBe("2026-03-01T20:33:44.168Z");
  expect(stamp("2026-03-01T20:33:44.168000+00:00")).toBe("2026-03-01T20:33:44.168Z");
  expect(stamp("2026-03-01T20:33:44")).toBe("2026-03-01T20:33:44.000Z");
  expect(stamp("")).toBeNull();
  expect(() => stamp("2026-03-01T20:33:44.1681Z")).toThrow("sub-millisecond");
  expect(() => stamp("2026-02-30T00:00:00Z")).toThrow();
});

test("settings JSON matches Python json.dumps(sort_keys=True, ensure_ascii=False)", () => {
  // The form the import stored: {"language": "en", "vocabulary": ""}
  expect(pythonJson({ vocabulary: "", language: "en" })).toBe(
    '{"language": "en", "vocabulary": ""}',
  );
  expect(pythonJson({ b: [1, 2.5, true, null], a: "é\n" })).toBe(
    '{"a": "é\\n", "b": [1, 2.5, true, null]}',
  );
});
