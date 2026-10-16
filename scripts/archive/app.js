"use strict";
const $ = (id) => document.getElementById(id);
const state = {
  offset: 0,
  total: 0,
  selected: null,
  sequence: 0,
  detailSequence: 0,
};
const number = (n) => (n || 0).toLocaleString();
const when = (s) => (s ? new Date(s).toLocaleString() : "Unknown date");
const size = (n) =>
  n > 1024 ** 3
    ? (n / 1024 ** 3).toFixed(2) + " GB"
    : n > 1024 ** 2
      ? (n / 1024 ** 2).toFixed(1) + " MB"
      : number(n) + " bytes";
function node(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}
async function api(path) {
  const r = await fetch(path);
  if (!r.ok) throw new Error((await r.json()).error || "Archive request failed");
  return r.json();
}
function error(e) {
  $("health").textContent = e.message;
  $("health").className = "error";
}
function href(base, path) {
  return "/files/" + (base + "/" + path).split("/").map(encodeURIComponent).join("/");
}
function disclosure(title, value) {
  const d = node("details");
  d.append(node("summary", title), node("pre", JSON.stringify(value, null, 2)));
  return d;
}
function fields(obj) {
  const t = node("table");
  for (const [k, v] of Object.entries(obj || {})) {
    const tr = node("tr");
    tr.append(
      node("td", k),
      node(
        "td",
        v == null ? "Not recorded" : typeof v === "object" ? JSON.stringify(v) : String(v),
      ),
    );
    t.append(tr);
  }
  return t;
}
async function dataset() {
  const d = await api("/api/dataset");
  const root = $("dataset");
  root.replaceChildren();
  for (const name of ["dataset", "migration", "verification", "completeness"]) {
    if (d[name]) root.append(disclosure(name, d[name]));
  }
  const files = node("details");
  files.append(
    node("summary", "Original export files and dictionaries · " + d.source_files.length),
  );
  for (const file of d.source_files) {
    const p = node("p");
    const link = node("a", file.path + " · " + size(file.bytes));
    link.href = "/files/" + file.path.split("/").map(encodeURIComponent).join("/");
    link.target = "_blank";
    link.rel = "noopener";
    p.append(link);
    files.append(p);
  }
  root.append(files);
}
async function summary() {
  const d = await api("/api/summary");
  const sums = (key) => d.sources.reduce((a, s) => a + (s[key] || 0), 0);
  $("stats").replaceChildren();
  for (const [label, value] of [
    ["Total records", number(sums("records"))],
    ["Transcriber", number(d.sources.find((s) => s.source === "transcriber")?.records)],
    ["Wispr history", number(d.sources.find((s) => s.source === "wispr-flow")?.records)],
    ["With audio", number(sums("audio"))],
    ["Unknown date", number(sums("undated"))],
  ]) {
    const e = node("div", undefined, "stat");
    e.append(node("strong", value), node("span", label));
    $("stats").append(e);
  }
  $("root").textContent = d.root;
  $("health").className = d.error ? "error" : "";
  $("health").textContent = d.error
    ? "Archive needs attention: " + d.error
    : d.last_transcriber_sync
      ? "Transcriber archive checked " +
        when(d.last_transcriber_sync) +
        ". New recordings are saved automatically."
      : "Loading archive status…";
}
async function records() {
  const seq = ++state.sequence;
  const query = new URLSearchParams({
    q: $("search").value,
    source: $("source").value,
    offset: state.offset,
  });
  const d = await api("/api/records?" + query);
  if (seq !== state.sequence) return;
  state.total = d.total;
  $("count").textContent = number(d.total) + " records";
  $("records").replaceChildren();
  for (const r of d.items) {
    const b = node("button", undefined, "record" + (state.selected === r.key ? " selected" : ""));
    b.dataset.key = r.key;
    const top = node("span", undefined, "top");
    top.append(
      node("span", when(r.timestamp)),
      node("span", r.source === "transcriber" ? "Transcriber" : "Wispr"),
    );
    b.append(
      top,
      node("span", r.preview || "Metadata only", "preview"),
      node(
        "span",
        [r.app, r.audio ? "Audio" : null, r.screenshot ? "Screenshot" : null]
          .filter(Boolean)
          .join(" · "),
        "tags",
      ),
    );
    b.onclick = () => detail(r.key).catch(error);
    $("records").append(b);
  }
  $("page").textContent = d.total
    ? `${state.offset + 1}–${Math.min(state.offset + 50, d.total)}`
    : "No matches";
  $("previous").disabled = state.offset === 0;
  $("next").disabled = state.offset + 50 >= d.total;
}
async function detail(key) {
  state.selected = key;
  const seq = ++state.detailSequence;
  for (const b of $("records").children) b.classList.toggle("selected", b.dataset.key === key);
  const d = await api("/api/record?" + new URLSearchParams({ key }));
  if (seq !== state.detailSequence) return;
  const m = d.metadata;
  const root = $("detail");
  root.replaceChildren(node("h2", when(m.timestamp)));
  const badges = node("div", undefined, "recordmeta");
  for (const text of [
    m.source === "transcriber" ? "Transcriber" : "Wispr history",
    m.status || "Status not recorded",
    m.mode,
    m.text.clean_variant ? "Clean text: " + m.text.clean_variant : null,
  ])
    if (text) badges.append(node("span", text, "pill"));
  root.append(badges);
  const cards = node("div", undefined, "texts");
  for (const name of ["raw", "clean"]) {
    const card = node("section", undefined, "textcard " + name);
    card.append(
      node("h3", name === "raw" ? "Raw recognition" : "Clean transcript"),
      node(
        "div",
        m.text[name] == null ? "Not recorded" : m.text[name] || "Empty transcript",
        "transcript",
      ),
    );
    const a = node("a", "Open " + name + ".txt", "rawlink");
    a.href = href(d.base, name + ".txt");
    a.target = "_blank";
    a.rel = "noopener";
    card.append(a);
    cards.append(card);
  }
  root.append(cards);
  const context = node("section", undefined, "section");
  context.append(node("h3", "Context"), fields(m.context));
  root.append(context);
  root.append(
    disclosure("All transcript variants", m.text.variants),
    disclosure("Archive metadata", m),
  );
  if (m.artifacts.length) {
    const section = node("section", undefined, "section");
    section.append(node("h3", "Attachments · " + m.artifacts.length));
    const files = node("div", undefined, "files");
    for (const a of m.artifacts) {
      const box = node("div", undefined, "file");
      const link = node("a", a.original_name + " · " + size(a.bytes));
      link.href = href(d.base, a.path);
      link.target = "_blank";
      link.rel = "noopener";
      box.append(link, node("small", "SHA-256 " + a.sha256));
      if (["audio", "original-audio"].includes(a.kind) && a.path.endsWith(".wav")) {
        const player = node("audio");
        player.controls = true;
        player.preload = "none";
        player.src = link.href;
        box.append(player);
      }
      if (a.kind === "screenshot") {
        const img = node("img");
        img.loading = "lazy";
        img.alt = "Archived source screenshot";
        img.src = link.href;
        box.append(img);
      }
      files.append(box);
    }
    section.append(files);
    root.append(section);
  }
  const versions = node("section", undefined, "section");
  versions.append(node("h3", "Original source data · " + d.versions.length + " versions"));
  for (const v of d.versions) {
    const section = node("details");
    section.append(node("summary", v.role + " · " + v.source_file));
    if (v.data.values) {
      const vfields = {};
      for (const [k, value] of Object.entries(v.data.values))
        vfields[k] =
          value.type === "null" ? null : Object.hasOwn(value, "value") ? value.value : value;
      section.append(fields(vfields));
    } else {
      section.append(fields(v.data));
    }
    section.append(disclosure("Exact archived JSON", v.data));
    versions.append(section);
  }
  root.append(versions);
}
let timer;
$("search").oninput = () => {
  clearTimeout(timer);
  timer = setTimeout(() => {
    state.offset = 0;
    records().catch(error);
  }, 220);
};
$("source").onchange = () => {
  state.offset = 0;
  records().catch(error);
};
$("previous").onclick = () => {
  state.offset = Math.max(0, state.offset - 50);
  records().catch(error);
};
$("next").onclick = () => {
  state.offset += 50;
  records().catch(error);
};
$("refresh").onclick = () => Promise.all([summary(), records(), dataset()]).catch(error);
Promise.all([summary(), records(), dataset()]).catch(error);
setInterval(() => summary().catch(error), 10000);
