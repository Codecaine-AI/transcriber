// The transcripts viewer: 3 tabs over the read-only API of Hub/src/viewer.ts.
// Every text from the API goes into the page as a text node (textContent). A search match is a
// <mark> element built here from the [start, end) offsets of the snippet. No innerHTML anywhere.
"use strict";

const $ = (id) => document.getElementById(id);

/// An element with optional text and class. Text is always set as a text node.
function node(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null) e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}

const number = (n) => (typeof n === "number" ? n.toLocaleString() : "Unknown");
const when = (s) => {
  if (!s) return "Unknown time";
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? String(s) : d.toLocaleString();
};
const size = (n) => {
  if (typeof n !== "number") return "Unknown";
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i === 0 ? `${number(n)} bytes` : `${v.toFixed(v >= 100 ? 0 : 1)} ${units[i]}`;
};
const seconds = (s) => {
  if (typeof s !== "number") return null;
  if (s < 60) return `${s.toFixed(1)} s`;
  const m = Math.floor(s / 60);
  return `${m} min ${Math.round(s - m * 60)} s`;
};
const ago = (s) => {
  const ms = Date.now() - new Date(s).getTime();
  if (!Number.isFinite(ms)) return "";
  const h = ms / 3_600_000;
  if (h < 1) return `${Math.max(0, Math.round(ms / 60_000))} min ago`;
  if (h < 48) return `${h.toFixed(1)} h ago`;
  return `${Math.round(h / 24)} days ago`;
};
const SOURCE = { transcriber: "Transcriber", "wispr-flow": "Wispr Flow" };

class ApiError extends Error {
  constructor(status, code, message) {
    super(message || code || `HTTP ${status}`);
    this.status = status;
    this.code = code;
  }
}

async function api(path, signal) {
  let r;
  try {
    r = await fetch(path, { signal, headers: { Accept: "application/json" } });
  } catch (e) {
    if (e.name === "AbortError") throw e;
    throw new ApiError(0, "network", "The viewer did not answer. Check the connection.");
  }
  if (!r.ok) {
    let body = {};
    try {
      body = await r.json();
    } catch {
      // A reply with no JSON body keeps the status only.
    }
    throw new ApiError(r.status, body.error, body.message || body.error || `HTTP ${r.status}`);
  }
  return r.json();
}

/// The error state of a view: the message and a Retry button.
function failure(message, retry) {
  const box = node("div", undefined, "failure");
  box.setAttribute("role", "alert");
  box.append(node("div", message));
  if (retry) {
    const b = node("button", "Retry");
    b.type = "button";
    b.addEventListener("click", retry);
    box.append(b);
  }
  return box;
}

function empty(title, text, small) {
  const box = node("div", undefined, small ? "empty small" : "empty");
  box.append(node("h2", title));
  if (text) box.append(node("p", text));
  return box;
}

/// A text with <mark> elements at the [start, end) offsets. Offsets are UTF-16 indexes, as the
/// server makes them with String.matchAll. Bad or overlapping offsets are skipped.
function marked(text, marks) {
  const frag = document.createDocumentFragment();
  let at = 0;
  for (const pair of Array.isArray(marks) ? marks : []) {
    const [start, end] = pair;
    if (!Number.isInteger(start) || !Number.isInteger(end)) continue;
    if (start < at || end <= start || end > text.length) continue;
    if (start > at) frag.append(document.createTextNode(text.slice(at, start)));
    frag.append(node("mark", text.slice(start, end)));
    at = end;
  }
  if (at < text.length) frag.append(document.createTextNode(text.slice(at)));
  return frag;
}

// ---- Tabs --------------------------------------------------------------------------------------

const TABS = { "/": "browse", "/index.html": "browse", "/insights": "insights", "/nas": "nas" };
const loaded = { browse: false, insights: false, nas: false };

function showTab(name) {
  for (const id of ["browse", "insights", "nas"]) $(id).hidden = id !== name;
  for (const a of document.querySelectorAll(".tabs a")) {
    if (a.dataset.tab === name) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
  document.title = `${name === "browse" ? "Browse" : name === "insights" ? "Insights" : "NAS"} · Transcripts`;
  if (!loaded[name]) {
    loaded[name] = true;
    if (name === "browse") loadList();
    if (name === "insights") loadInsights();
    if (name === "nas") loadNas();
  }
}

function route() {
  showTab(TABS[location.pathname] || "browse");
}

for (const a of document.querySelectorAll(".tabs a")) {
  a.addEventListener("click", (event) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
    event.preventDefault();
    if (location.pathname !== a.getAttribute("href"))
      history.pushState(null, "", a.getAttribute("href"));
    route();
  });
}
window.addEventListener("popstate", route);

// ---- Browse ------------------------------------------------------------------------------------

const browse = {
  page: 1,
  total: 0,
  selected: null,
  listSequence: 0,
  detailSequence: 0,
  listAbort: null,
  modes: new Set(),
};

function filterParams() {
  const p = new URLSearchParams();
  const q = $("q").value.trim();
  if (q) p.set("q", q);
  for (const id of ["source", "mode", "from", "to", "audio"]) {
    const v = $(id).value;
    if (v) p.set(id, v);
  }
  if (!q && browse.page > 1) p.set("page", String(browse.page));
  return p;
}

/// Add the modes of the list rows to the mode filter. The API has no list of modes, and it refuses
/// a mode that no recording has, so the filter offers only modes it has seen.
function learnModes(items) {
  const select = $("mode");
  for (const item of items) {
    if (!item.mode || browse.modes.has(item.mode)) continue;
    browse.modes.add(item.mode);
    const o = node("option", item.mode);
    o.value = item.mode;
    select.append(o);
  }
}

function listItem(item, searching) {
  const b = node("button", undefined, "record");
  b.type = "button";
  b.dataset.id = item.recording_id;
  if (item.recording_id === browse.selected) b.classList.add("selected");
  const top = node("span", undefined, "top");
  top.append(
    node("span", when(item.recorded_at)),
    node("span", seconds(item.duration_seconds) || ""),
  );
  let preview;
  if (searching && item.snippet && typeof item.snippet.text === "string") {
    preview = node("span", undefined, "preview");
    preview.append(marked(item.snippet.text, item.snippet.marks));
  } else if (item.preview) {
    preview = node("span", item.preview, "preview");
  } else {
    preview = node("span", "No text", "preview none");
  }
  const tags = [SOURCE[item.source] || item.source, item.mode || "no mode", item.status];
  if (item.app) tags.push(item.app);
  tags.push(item.has_audio ? "audio" : "text only");
  b.append(top, preview, node("span", tags.join(" · "), "tags"));
  b.addEventListener("click", () => select(item.recording_id));
  return b;
}

async function loadList() {
  const sequence = ++browse.listSequence;
  browse.listAbort?.abort();
  const abort = new AbortController();
  browse.listAbort = abort;
  const list = $("records");
  const q = $("q").value.trim();
  $("count").textContent = "Loading…";
  $("order").textContent = q ? "Best match first" : "Newest first";
  let data;
  try {
    data = await api(`/api/records?${filterParams()}`, abort.signal);
  } catch (e) {
    if (e.name === "AbortError" || sequence !== browse.listSequence) return;
    $("count").textContent = "";
    $("page").textContent = "";
    $("previous").disabled = true;
    $("next").disabled = true;
    list.replaceChildren(failure(`The list did not load: ${e.message}`, loadList));
    return;
  }
  if (sequence !== browse.listSequence) return;
  const items = Array.isArray(data.items) ? data.items : [];
  learnModes(items);
  browse.total = data.total || 0;
  const searching = typeof data.query === "string";
  $("count").textContent = searching
    ? `${number(browse.total)} ${browse.total === 1 ? "match" : "matches"} (top 20)`
    : `${number(browse.total)} ${browse.total === 1 ? "recording" : "recordings"}`;
  const pages = searching ? 1 : Math.max(1, Math.ceil(browse.total / (data.page_size || 20)));
  $("page").textContent = `Page ${number(browse.page)} of ${number(pages)}`;
  $("previous").disabled = searching || browse.page <= 1;
  $("next").disabled = searching || browse.page >= pages;
  if (!items.length) {
    list.replaceChildren(
      searching
        ? empty("No matches", "No cleaned text has these words with these filters.", true)
        : empty("No recordings", "No recording fits these filters.", true),
    );
    return;
  }
  list.replaceChildren(...items.map((item) => listItem(item, searching)));
  list.scrollTop = 0;
}

let searchTimer = 0;
function refilter() {
  browse.page = 1;
  clearTimeout(searchTimer);
  loadList();
}
$("q").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    browse.page = 1;
    loadList();
  }, 250);
});
$("filters").addEventListener("submit", (event) => {
  event.preventDefault();
  refilter();
});
for (const id of ["source", "mode", "from", "to", "audio"])
  $(id).addEventListener("change", refilter);
$("clear").addEventListener("click", () => {
  for (const id of ["q", "source", "mode", "from", "to", "audio"]) $(id).value = "";
  refilter();
});
$("previous").addEventListener("click", () => {
  if (browse.page > 1) {
    browse.page--;
    loadList();
  }
});
$("next").addEventListener("click", () => {
  browse.page++;
  loadList();
});

// ---- Record pane -------------------------------------------------------------------------------

function fieldsTable(obj) {
  const t = node("table", undefined, "fields");
  const body = node("tbody");
  for (const [k, v] of Object.entries(obj || {})) {
    const tr = node("tr");
    tr.append(
      node("td", k),
      node(
        "td",
        v === null || v === undefined
          ? "Not recorded"
          : typeof v === "object"
            ? JSON.stringify(v)
            : String(v),
      ),
    );
    body.append(tr);
  }
  t.append(body);
  return t;
}

function textCard(title, about, text, clean) {
  const card = node("div", undefined, clean ? "textcard clean" : "textcard");
  card.append(node("h3", title), node("p", about, "about"), node("p", text, "transcript"));
  return card;
}

/// Why the FLAC cannot play, in words, from a HEAD request to the audio route.
async function audioProblem(src) {
  let r;
  try {
    r = await fetch(src, { method: "HEAD" });
  } catch {
    return "The audio did not load: the viewer did not answer.";
  }
  if (r.ok) return null;
  // A HEAD reply has no body, so the GET body names the error code.
  let code = "";
  try {
    const g = await fetch(src, { headers: { Range: "bytes=0-0" } });
    if (!g.ok) code = (await g.json()).error || "";
    else return null;
  } catch {
    // Keep the status only.
  }
  if (r.status === 503 && code === "nas_window") {
    const retry = Number(r.headers.get("Retry-After"));
    const until =
      Number.isFinite(retry) && retry > 0 ? ` Try again in ${Math.ceil(retry / 60)} min.` : "";
    return `The NAS is busy with its daily job from 10:57 to 12:00 UTC, so the audio cannot play now.${until}`;
  }
  if (r.status === 503)
    return "The transcripts share is not mounted, so the audio cannot play now.";
  if (code === "not_on_share") return "The audio row exists, but its FLAC is not on the share.";
  if (r.status === 404) return "The audio file was not found.";
  return `The audio did not load (HTTP ${r.status}${code ? `, ${code}` : ""}).`;
}

function playerSection(data) {
  const section = node("div", undefined, "section");
  section.append(node("h3", "Audio"));
  const box = node("div", undefined, "player");
  section.append(box);
  const sha = data.audio && data.audio.sha256;
  if (!sha) {
    box.append(node("p", "No audio"));
    box.append(node("small", "This recording has text only. No FLAC was kept for it."));
    return section;
  }
  const src = `/audio/${encodeURIComponent(sha)}.flac`;
  const info = [size(data.audio.bytes)];
  if (data.audio.sample_rate) info.push(`${number(data.audio.sample_rate)} Hz`);
  if (data.audio.sample_rate && data.audio.frame_count)
    info.push(seconds(data.audio.frame_count / data.audio.sample_rate));
  const note = node("p", "", "note");
  note.hidden = true;
  const player = node("audio");
  player.controls = true;
  player.preload = "metadata";
  const explain = async () => {
    const why = await audioProblem(src);
    note.textContent = why || "The browser could not play this FLAC.";
    note.hidden = false;
  };
  player.addEventListener("error", explain);
  player.src = src;
  box.append(node("p", "FLAC"), node("small", `${info.join(" · ")} · ${sha}`), player, note);
  return section;
}

function renderRecord(data) {
  const rec = data.recording || {};
  const detail = $("detail");
  const parts = [];
  parts.push(node("h2", when(rec.recorded_at)));
  const meta = node("div", undefined, "recordmeta");
  const pills = [
    SOURCE[rec.source] || rec.source,
    rec.mode ? `mode ${rec.mode}` : "no mode",
    rec.status,
    rec.app,
    seconds(rec.duration_seconds),
    rec.language,
    data.device ? `${data.device.name} · ${data.device.owner}` : null,
  ];
  for (const p of pills) if (p) meta.append(node("span", p, "pill"));
  parts.push(meta);
  parts.push(playerSection(data));

  const cleanups = Array.isArray(data.cleanups) ? data.cleanups : [];
  const transcriptions = Array.isArray(data.transcriptions) ? data.transcriptions : [];
  const texts = node("div", undefined, "section");
  texts.append(node("h3", "Text"));
  const grid = node("div", undefined, "texts");
  for (const c of [...cleanups].reverse()) {
    const about = [c.engine, c.model, c.status, when(c.created_at)].filter(Boolean).join(" · ");
    grid.append(textCard("Cleaned text", about, c.text, true));
  }
  for (const t of [...transcriptions].reverse()) {
    const about = [
      t.provider,
      t.model,
      t.model_version,
      t.detected_language,
      typeof t.processing_seconds === "number"
        ? `${t.processing_seconds.toFixed(1)} s to transcribe`
        : null,
      when(t.created_at),
    ]
      .filter(Boolean)
      .join(" · ");
    grid.append(textCard("Raw transcription", about, t.text, false));
  }
  if (!cleanups.length && !transcriptions.length)
    grid.append(empty("No text", "This recording has no transcription and no cleanup.", true));
  texts.append(grid);
  parts.push(texts);

  const fields = node("details");
  fields.append(node("summary", "Every recording field"), fieldsTable(rec));
  if (data.audio) fields.append(node("p", "Audio row", "sub"), fieldsTable(data.audio));
  if (data.device) fields.append(node("p", "Device", "sub"), fieldsTable(data.device));
  const more = node("div", undefined, "section");
  more.append(fields);
  parts.push(more);
  detail.replaceChildren(...parts);
}

async function select(id) {
  browse.selected = id;
  for (const b of document.querySelectorAll(".record"))
    b.classList.toggle("selected", b.dataset.id === id);
  const sequence = ++browse.detailSequence;
  const detail = $("detail");
  detail.replaceChildren(node("p", "Loading the recording…", "loading"));
  if (window.matchMedia("(max-width: 700px)").matches) detail.scrollIntoView({ block: "start" });
  try {
    const data = await api(`/api/records/${encodeURIComponent(id)}`);
    if (sequence !== browse.detailSequence) return;
    renderRecord(data);
  } catch (e) {
    if (sequence !== browse.detailSequence) return;
    detail.replaceChildren(failure(`The recording did not load: ${e.message}`, () => select(id)));
  }
}

// ---- Insights ----------------------------------------------------------------------------------

/// The class of a bar fill: its width as a share of the largest value, in steps of 2 %.
const widthClass = (value, max) =>
  `w${max > 0 && value > 0 ? Math.max(2, Math.round((value / max) * 50) * 2) : 0}`;

function statCard(value, label, formula) {
  const card = node("div", undefined, "card");
  card.append(node("strong", value), node("div", label, "label"), node("div", formula, "formula"));
  return card;
}

function barCard(title, rows, key, formula) {
  const card = node("div", undefined, "card");
  card.append(node("h3", title));
  const sorted = [...rows].sort((a, b) => b[key] - a[key]).slice(0, 12);
  const max = sorted.length ? sorted[0][key] : 0;
  for (const row of sorted) {
    const bar = node("div", undefined, "bar");
    const name = node("span", row.name, "name");
    name.title = row.app || "No app";
    const track = node("div", undefined, "track");
    track.append(node("div", undefined, `fill ${widthClass(row[key], max)}`));
    bar.append(name, node("span", number(row[key]), "value"), track);
    card.append(bar);
  }
  if (rows.length > sorted.length)
    card.append(node("p", `${number(rows.length - sorted.length)} more apps not shown`, "sub"));
  card.append(node("div", formula, "formula"));
  return card;
}

async function loadInsights() {
  const body = $("insights-body");
  body.replaceChildren(node("p", "Counting every take…", "loading"));
  let data;
  try {
    data = await api("/api/insights");
  } catch (e) {
    body.replaceChildren(failure(`Insights did not load: ${e.message}`, loadInsights));
    return;
  }
  if (!data.takes || !data.takes.value) {
    body.replaceChildren(empty("No takes yet", "The database has no recordings to count."));
    return;
  }
  const wpm = data.words_per_minute;
  const cards = node("div", undefined, "cards");
  cards.append(
    statCard(
      wpm.value === null ? "No value" : number(wpm.value),
      "WORDS PER MINUTE",
      `${wpm.formula}: ${number(wpm.words)} words in ${number(wpm.seconds)} s`,
    ),
    statCard(
      number(data.total_words.value),
      "TOTAL WORDS DICTATED",
      `${number(data.takes.value)} takes · ${number(data.takes.days)} days with a take. ${data.total_words.formula}`,
    ),
    statCard(number(data.takes.value), "TAKES", data.takes.formula),
  );
  const rows = (data.apps && data.apps.rows) || [];
  const bars = node("div", undefined, "bars");
  if (rows.length) {
    bars.append(
      barCard("Takes per app", rows, "takes", data.apps.formula),
      barCard("Words per app", rows, "words", data.apps.formula),
    );
  }
  body.replaceChildren(
    cards,
    rows.length ? bars : empty("No apps", "No take names an app.", true),
    node("p", `Computed ${when(data.computed_at)}. The numbers are kept for 1 min.`, "computed"),
  );
}

// ---- NAS ---------------------------------------------------------------------------------------

const isUnavailable = (v) => typeof v === "object" && v !== null && v.unavailable === true;

/// One table cell, labeled for the phone layout. content is a string, a node or a list of them.
function cell(label, content) {
  const td = node("td");
  td.dataset.label = label;
  const wrap = node("div");
  for (const c of Array.isArray(content) ? content : [content])
    wrap.append(typeof c === "string" ? document.createTextNode(c) : c);
  td.append(wrap);
  return td;
}

/// A value, or "Unavailable" with its reason.
function value(v, show) {
  if (isUnavailable(v)) {
    const span = node("span", "Unavailable", "unavail");
    span.append(node("small", v.reason || "no reason given"));
    return span;
  }
  if (v === null || v === undefined) return node("span", "None", "unavail");
  return show(v);
}

const timeWithAgo = (s) => {
  const span = node("span", when(s));
  span.append(node("small", ago(s), "sub"));
  return span;
};

function backupCell(b) {
  if (isUnavailable(b)) return value(b);
  if (b && typeof b === "object" && "trace_db" in b) {
    const span = node("span");
    for (const [label, part] of [
      ["Trace database", b.trace_db],
      ["Token Gateway", b.gateway],
    ]) {
      const line = node("div");
      line.append(node("span", `${label}: `));
      line.append(
        value(part, (p) => {
          const s = node("span", p.name);
          s.append(node("small", `${when(p.modified)} · ${ago(p.modified)}`, "sub"));
          return s;
        }),
      );
      span.append(line);
    }
    return span;
  }
  return value(b, (m) => {
    const s = node("span", m.name || m.day || "Backup");
    const bits = [when(m.created_at), ago(m.created_at), size(m.bytes)];
    if (m.match === true) bits.push("sha256 matches the manifest");
    if (m.match === false) bits.push("sha256 does not match the manifest");
    s.append(node("small", bits.join(" · "), "sub"));
    return s;
  });
}

function sharesTable(shares) {
  const t = node("table", undefined, "stack");
  const head = node("thead");
  const hr = node("tr");
  const labels = ["Share", "Files", "Bytes", "Newest write", "Newest backup", "Snapshots"];
  for (const l of labels) hr.append(node("th", l));
  head.append(hr);
  const body = node("tbody");
  for (const s of shares) {
    const tr = node("tr");
    const name = node("strong", s.name);
    const source = s.totals_source;
    const totals = node(
      "small",
      source && source.generated
        ? `Totals from ${source.file}, ${source.age_hours} h old`
        : "No totals file time",
      "sub",
    );
    tr.append(
      cell(labels[0], [name, totals]),
      cell(
        labels[1],
        value(s.files, (n) => node("span", number(n), "num")),
      ),
      cell(
        labels[2],
        value(s.bytes, (n) => {
          const span = node("span", size(n), "num");
          span.append(node("small", `${number(n)} bytes`, "sub"));
          return span;
        }),
      ),
      cell(labels[3], value(s.newest_write, timeWithAgo)),
      cell(labels[4], backupCell(s.newest_backup)),
      cell(
        labels[5],
        value(s.snapshots, (sn) => {
          const span = node(
            "span",
            `${number(sn.count)} ${sn.count === 1 ? "snapshot" : "snapshots"}`,
          );
          span.append(
            node(
              "small",
              sn.newest ? `Newest ${when(sn.newest)} · ${ago(sn.newest)}` : "No snapshot",
              "sub",
            ),
            node(
              "small",
              `From the DSM ${sn.from === "api" ? "API list" : "snapshot folders"}`,
              "sub",
            ),
          );
          return span;
        }),
      ),
    );
    body.append(tr);
  }
  t.append(head, body);
  return t;
}

function alarmBanner(hw) {
  if (isUnavailable(hw)) {
    const b = node("div", undefined, "banner unknown");
    b.append(node("strong", "High-water alarm: unknown"), node("span", hw.reason));
    return b;
  }
  if (hw.alarm) {
    const b = node("div", undefined, "banner alarm");
    b.setAttribute("role", "alert");
    b.append(node("strong", "High-water alarm: a live count is below a backup"));
    for (const d of hw.drops || [])
      b.append(
        node(
          "div",
          `${d.table}: ${number(d.live)} live, ${number(d.highest)} in a backup manifest (${number(d.highest - d.live)} fewer)`,
        ),
      );
    return b;
  }
  const b = node("div", undefined, "banner");
  const m = hw.manifests || {};
  b.append(
    node("strong", "High-water alarm: off"),
    node(
      "span",
      `Every live count is at or above its highest count in ${number(m.in_db)} manifests in db/ and ${number(m.in_superseded)} in db/superseded.`,
    ),
  );
  return b;
}

function countsTable(database, hw) {
  const t = node("table", undefined, "stack");
  const head = node("thead");
  const hr = node("tr");
  const labels = ["Table", "Live rows", "Highest in a backup"];
  for (const l of labels) hr.append(node("th", l));
  head.append(hr);
  const body = node("tbody");
  const counts = database.counts;
  if (isUnavailable(counts)) {
    const tr = node("tr");
    tr.append(cell(labels[0], "All tables"), cell(labels[1], value(counts)), cell(labels[2], "—"));
    body.append(tr);
  } else {
    const highest = isUnavailable(hw) ? null : hw.highest || {};
    for (const [table, n] of Object.entries(counts || {})) {
      const tr = node("tr");
      tr.append(
        cell(labels[0], table),
        cell(labels[1], node("span", number(n), "num")),
        cell(
          labels[2],
          highest === null
            ? value(hw)
            : typeof highest[table] === "number"
              ? node("span", number(highest[table]), "num")
              : node("span", "Not in the manifests", "sub"),
        ),
      );
      body.append(tr);
    }
  }
  t.append(head, body);
  return t;
}

function miniCard(title, content) {
  const card = node("div", undefined, "card");
  card.append(node("div", title, "label"));
  const inner = node("div");
  inner.append(content);
  card.append(inner);
  return card;
}

function block(title, ...content) {
  const b = node("div", undefined, "block");
  b.append(node("h3", title), ...content);
  return b;
}

function tableCard(table) {
  const c = node("div", undefined, "tablecard");
  c.append(table);
  return c;
}

async function loadNas() {
  const body = $("nas-body");
  body.replaceChildren(node("p", "Reading the NAS status file…", "loading"));
  let data;
  try {
    data = await api("/api/nas");
  } catch (e) {
    body.replaceChildren(failure(`The NAS status did not load: ${e.message}`, loadNas));
    return;
  }
  if (!data.available) {
    body.replaceChildren(
      empty("No NAS status yet", data.message || "The NAS status job has not run yet."),
    );
    return;
  }
  const s = data.status;
  if (!s || typeof s !== "object" || !Array.isArray(s.shares)) {
    body.replaceChildren(failure("The NAS status file does not have the expected shape.", loadNas));
    return;
  }
  const parts = [];
  const top = node("p", undefined, "sub");
  top.textContent = `Checked ${when(s.checked_at)} (${ago(s.checked_at)}). The daily status job writes this file after 07:30 Central. A page load never touches the NAS.`;
  parts.push(alarmBanner(s.high_water), top);

  parts.push(
    block(
      "Shares",
      s.shares.length ? tableCard(sharesTable(s.shares)) : empty("No shares", "", true),
    ),
  );

  const database = s.database || {};
  const mini = node("div", undefined, "mini");
  mini.append(
    miniCard(
      "BACKUP AGE",
      value(s.backup_age, (a) => {
        const span = node("strong", `${a.hours} h`);
        span.append(
          node("small", `Newest copy ${a.day}, made ${when(a.newest_created_at)}`, "sub"),
        );
        return span;
      }),
    ),
    miniCard(
      "LAST CLIENT SYNC",
      value(database.last_sync, (l) => {
        const span = node("strong", `${l.hours_ago} h ago`);
        span.append(
          node(
            "small",
            `${when(l.time)} · from ${l.from === "state_file" ? "last-sync.json" : "the hub log"}`,
            "sub",
          ),
        );
        return span;
      }),
    ),
    miniCard(
      "NEWEST RECORDING",
      value(database.newest_recorded_at, (t) => {
        const span = node("strong", ago(t));
        span.append(node("small", when(t), "sub"));
        return span;
      }),
    ),
  );
  parts.push(block("Backup and sync", mini));
  parts.push(block("Database counts", tableCard(countsTable(database, s.high_water))));

  const list = Array.isArray(s.unavailable) ? s.unavailable : [];
  if (list.length) {
    const t = node("table", undefined, "stack");
    const head = node("thead");
    const hr = node("tr");
    hr.append(node("th", "Field"), node("th", "Reason"));
    head.append(hr);
    const tb = node("tbody");
    for (const u of list) {
      const tr = node("tr");
      tr.append(cell("Field", u.field), cell("Reason", u.reason));
      tb.append(tr);
    }
    t.append(head, tb);
    parts.push(block(`Unavailable fields (${list.length})`, tableCard(t)));
  } else {
    parts.push(block("Unavailable fields", node("p", "None. The job read every field.", "sub")));
  }

  const link = node("a", "Open traces.lascari.dev");
  link.href = "https://traces.lascari.dev";
  const p = node("p", "The trace runs and their NAS copies are on the traces page: ");
  p.append(link);
  parts.push(block("Trace runs", p));
  parts.push(node("p", `Status file written ${when(data.file_time)}.`, "computed"));
  body.replaceChildren(...parts);
}

route();
