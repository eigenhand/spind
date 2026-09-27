// Spind — Copyright (C) 2026 Christoph Lindl-Guk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Self-contained share page uploaded into shared folders as
/// ".spind-share.html". A full file manager on top of the box's WebDAV:
/// browsing, search, sorting, previews, Collabora editing and — on
/// read-write shares — upload, rename, delete and new documents.
///
/// Read-write share hosts answer PROPFIND, so the page lists live. On
/// read-only hosts (GET only) it falls back to the manifest Spind
/// writes next to this file.
enum ShareWebUI {
    static let fileName = ".spind-share.html"

    /// - Parameter authorization: Basic-Auth value of the share account.
    ///   Browsers do not reuse credentials from a `user:pass@host` link for
    ///   subresources (verified: fetch/PROPFIND/img all get 401), so the
    ///   page must send the header itself. It carries no extra risk: the
    ///   page is only readable with exactly these credentials.
    static func html(folderName: String, authorization: String = "") -> String {
        let title = folderName.isEmpty ? "Freigabe" : folderName
        return #"""
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex">
<title>\#(title) – Spind</title>
<style>
:root {
  --bg:#f6f7f9; --card:#fff; --text:#111827; --muted:#6b7280; --faint:#9aa3af;
  --line:#e6e8ec; --accent:#2563eb; --accent-soft:rgba(37,99,235,.09);
  --hover:rgba(17,24,39,.035); --danger:#dc2626; --ok:#16a34a;
  --shadow:0 1px 2px rgba(16,24,40,.04), 0 8px 24px rgba(16,24,40,.06);
  --c-doc:#2563eb; --c-sheet:#16a34a; --c-slide:#ea580c;
  --c-media:#7c3aed; --c-pdf:#dc2626; --c-arch:#a16207; --c-gen:#6b7280;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg:#0d1117; --card:#151b23; --text:#e6edf3; --muted:#8b949e; --faint:#6e7681;
    --line:#222b36; --accent:#589bff; --accent-soft:rgba(88,155,255,.14);
    --hover:rgba(255,255,255,.045);
    --shadow:0 1px 2px rgba(0,0,0,.3), 0 12px 32px rgba(0,0,0,.28);
    --c-doc:#589bff; --c-sheet:#3fb950; --c-slide:#f0883e;
    --c-media:#a371f7; --c-pdf:#f85149; --c-arch:#d29922; --c-gen:#8b949e;
  }
}
* { box-sizing:border-box; margin:0; }
html { -webkit-text-size-adjust:100%; }
body {
  font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  background:var(--bg); color:var(--text); min-height:100vh;
  padding:36px 20px 80px; -webkit-font-smoothing:antialiased;
}
.wrap { max-width:900px; margin:0 auto; }
svg.i { width:16px; height:16px; stroke:currentColor; fill:none;
  stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round; flex:none; }

/* Header */
header { display:flex; align-items:center; gap:14px; margin-bottom:20px; }
.brand { width:44px; height:44px; border-radius:13px; flex:none; display:grid; place-items:center;
  background:linear-gradient(150deg,#3b82f6,#22b8f5); color:#fff; }
.brand svg { width:23px; height:23px; stroke-width:1.9; }
h1 { font-size:19px; font-weight:640; letter-spacing:-.015em; line-height:1.25; }
.sub { color:var(--muted); font-size:13px; margin-top:1px; }

/* Card + toolbar */
.card { background:var(--card); border:1px solid var(--line); border-radius:14px;
  box-shadow:var(--shadow); overflow:hidden; }
.toolbar { display:flex; align-items:center; gap:8px; padding:10px 12px;
  border-bottom:1px solid var(--line); flex-wrap:wrap; }
.crumbs { display:flex; align-items:center; gap:3px; font-size:13.5px;
  min-width:0; overflow:hidden; padding-left:4px; }
.crumbs a { color:var(--muted); text-decoration:none; border-radius:6px; padding:3px 5px; }
.crumbs a:hover { color:var(--text); background:var(--hover); }
.crumbs .sep { color:var(--faint); display:grid; place-items:center; }
.crumbs .sep svg { width:14px; height:14px; }
.crumbs .here { font-weight:600; padding:3px 5px; }
.grow { flex:1 1 auto; }
.search { position:relative; display:flex; align-items:center; }
.search svg { position:absolute; left:9px; color:var(--faint); width:15px; height:15px; }
.search input { padding:7px 10px 7px 30px; width:190px; font-size:13.5px; font-family:inherit;
  border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--text);
  outline:none; transition:border-color .15s, width .2s; }
.search input:focus { border-color:var(--accent); width:230px; }
select.sort { padding:7px 8px; font-size:13.5px; font-family:inherit; border:1px solid var(--line);
  border-radius:8px; background:var(--bg); color:var(--muted); outline:none; cursor:pointer; }
.seg { display:flex; border:1px solid var(--line); border-radius:8px; overflow:hidden; }
.seg button { padding:7px 9px; background:var(--bg); border:none; color:var(--muted);
  cursor:pointer; display:grid; place-items:center; }
.seg button.on { background:var(--accent-soft); color:var(--accent); }
.btn { display:inline-flex; align-items:center; gap:6px; padding:7px 12px; font-size:13.5px;
  font-weight:560; font-family:inherit; border-radius:8px; border:1px solid var(--line);
  background:var(--bg); color:var(--text); cursor:pointer; text-decoration:none;
  transition:background .15s, border-color .15s; white-space:nowrap; }
.btn:hover { background:var(--hover); }
.btn.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
.btn.primary:hover { filter:brightness(1.07); }
.btn.ghost { border-color:transparent; background:transparent; color:var(--muted); padding:7px 9px; }
.btn.ghost:hover { background:var(--hover); color:var(--text); }

/* Rows */
.row { display:flex; align-items:center; gap:12px; padding:9px 14px;
  border-bottom:1px solid var(--line); text-decoration:none; color:inherit; position:relative; }
.row:last-child { border-bottom:none; }
.row:hover { background:var(--hover); }
a.row { cursor:pointer; }
.tile-ico, .ico { width:36px; height:36px; border-radius:9px; display:grid; place-items:center;
  flex:none; overflow:hidden; background:var(--hover); }
.ico svg { width:18px; height:18px; }
.ico img, .tile-ico img { width:100%; height:100%; object-fit:cover; }
.c-doc { color:var(--c-doc); } .c-sheet { color:var(--c-sheet); } .c-slide { color:var(--c-slide); }
.c-media { color:var(--c-media); } .c-pdf { color:var(--c-pdf); } .c-arch { color:var(--c-arch); }
.c-gen { color:var(--c-gen); } .c-folder { color:var(--accent); }
.info { flex:1; min-width:0; }
.name { font-size:14.5px; font-weight:520; overflow:hidden; text-overflow:ellipsis;
  white-space:nowrap; letter-spacing:-.005em; }
.meta { color:var(--muted); font-size:12.5px; white-space:nowrap; margin-top:1px; }
.edit { padding:5px 11px; font-size:12.5px; font-weight:600; border-radius:7px;
  color:var(--accent); background:var(--accent-soft); text-decoration:none; white-space:nowrap; }
.edit:hover { filter:brightness(1.08); }
.acts { display:flex; gap:2px; align-items:center; flex:none; opacity:0; transition:opacity .12s; }
.row:hover .acts, .row:focus-within .acts { opacity:1; }
@media (hover:none) { .acts { opacity:1; } }
.act { width:30px; height:30px; border-radius:7px; border:none; background:transparent;
  color:var(--faint); cursor:pointer; display:grid; place-items:center; }
.act:hover { background:var(--hover); color:var(--text); }
.act.danger:hover { color:var(--danger); }

/* Grid */
.grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(148px,1fr)); gap:12px; padding:14px; }
.tile { border:1px solid var(--line); border-radius:11px; overflow:hidden; cursor:pointer;
  background:var(--bg); transition:border-color .15s, transform .1s; }
.tile:hover { border-color:var(--accent); transform:translateY(-1px); }
.tile .thumb { aspect-ratio:4/3; display:grid; place-items:center; overflow:hidden; }
.tile .thumb svg { width:30px; height:30px; }
.tile .thumb img { width:100%; height:100%; object-fit:cover; }
.tile .cap { padding:8px 10px 10px; border-top:1px solid var(--line); }
.tile .name { font-size:13px; } .tile .meta { font-size:11.5px; }

/* States */
.state { padding:52px 24px; text-align:center; color:var(--muted); font-size:14px; }
.state svg { width:30px; height:30px; color:var(--faint); margin-bottom:10px; }
.spinner { width:20px; height:20px; margin:0 auto 12px; border:2.2px solid var(--line);
  border-top-color:var(--accent); border-radius:50%; animation:spin .75s linear infinite; }
@keyframes spin { to { transform:rotate(360deg); } }
footer { text-align:center; color:var(--faint); font-size:12px; margin-top:18px; }
footer b { color:var(--muted); font-weight:600; }

/* Menu */
.menu { position:absolute; z-index:50; background:var(--card); border:1px solid var(--line);
  border-radius:10px; box-shadow:var(--shadow); padding:5px; min-width:190px; display:none; }
.menu.on { display:block; }
.menu button { display:flex; align-items:center; gap:9px; width:100%; padding:8px 10px;
  font-size:13.5px; font-family:inherit; background:none; border:none; color:var(--text);
  border-radius:7px; cursor:pointer; text-align:left; }
.menu button:hover { background:var(--hover); }
.menu button svg { color:var(--muted); }

/* Dialog */
.backdrop { position:fixed; inset:0; background:rgba(9,12,18,.5); backdrop-filter:blur(2px);
  display:none; place-items:center; z-index:100; padding:20px; }
.backdrop.on { display:grid; }
.dialog { background:var(--card); border:1px solid var(--line); border-radius:14px;
  box-shadow:var(--shadow); padding:20px; width:min(400px,100%); }
.dialog h3 { font-size:15.5px; font-weight:620; margin-bottom:4px; }
.dialog p { font-size:13.5px; color:var(--muted); margin-bottom:14px; }
.dialog input, .dialog select { width:100%; padding:9px 11px; font-size:14px; font-family:inherit;
  border:1px solid var(--line); border-radius:9px; background:var(--bg); color:var(--text);
  outline:none; margin-bottom:14px; }
.dialog input:focus, .dialog select:focus { border-color:var(--accent); }
.dialog .buttons { display:flex; justify-content:flex-end; gap:8px; }

/* Drop zone */
#drop { position:fixed; inset:0; background:rgba(37,99,235,.1); backdrop-filter:blur(2px);
  display:none; place-items:center; z-index:60; }
#drop.on { display:grid; }
#drop div { background:var(--card); padding:22px 30px; border-radius:14px; font-weight:600;
  border:2px dashed var(--accent); display:flex; align-items:center; gap:10px; color:var(--accent); }

/* Viewer */
#viewer { position:fixed; inset:0; background:rgba(8,11,16,.94); z-index:70;
  display:none; flex-direction:column; }
#viewer.on { display:flex; }
#viewer .top { display:flex; align-items:center; gap:10px; padding:12px 14px; color:#e9eef5; }
#viewer .top .name { font-size:14px; font-weight:560; }
#viewer .top .btn { background:rgba(255,255,255,.08); border-color:transparent; color:#e9eef5; }
#viewer .top .btn:hover { background:rgba(255,255,255,.16); }
#viewer .body { flex:1; display:grid; place-items:center; overflow:auto; padding:0 16px 18px; }
#viewer img, #viewer video { max-width:100%; max-height:100%; border-radius:10px; }
#viewer iframe { width:100%; height:100%; border:0; background:#fff; border-radius:10px; }
#viewer pre { max-width:860px; width:100%; max-height:100%; overflow:auto; background:var(--card);
  color:var(--text); padding:18px; border-radius:12px; font:13px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
  white-space:pre-wrap; }
.nav { position:absolute; top:50%; transform:translateY(-50%); color:#fff; width:42px; height:42px;
  background:rgba(255,255,255,.1); border:none; border-radius:50%; cursor:pointer;
  display:grid; place-items:center; }
.nav:hover { background:rgba(255,255,255,.2); }
.nav.prev { left:14px; } .nav.next { right:14px; }
.nav svg { width:20px; height:20px; }

/* Progress + toasts */
#progress { position:fixed; left:0; right:0; top:0; height:2.5px; z-index:80; }
#progress div { height:100%; width:0; background:var(--accent); transition:width .2s; }
#toasts { position:fixed; bottom:20px; left:50%; transform:translateX(-50%);
  display:flex; flex-direction:column; gap:8px; z-index:90; }
.toast { background:var(--card); border:1px solid var(--line); border-radius:10px;
  padding:10px 15px; font-size:13.5px; box-shadow:var(--shadow); display:flex; align-items:center; gap:8px;
  animation:rise .18s ease-out; }
@keyframes rise { from { opacity:0; transform:translateY(6px); } }
.toast.err { color:var(--danger); } .toast.ok { color:var(--ok); }

@media (max-width:660px) {
  body { padding:20px 12px 70px; }
  .toolbar { padding:10px; }
  .crumbs { order:1; flex:1 1 auto; }
  .search { order:3; flex:1 1 100%; }
  .search input, .search input:focus { width:100%; }
  .meta .date { display:none; }
  .row { padding:9px 11px; }
}
</style>
</head>
<body>
<svg style="display:none">
  <symbol id="i-cloud" viewBox="0 0 24 24"><path d="M4 13h13a3.5 3.5 0 0 1 0 7H7a4 4 0 0 1-.9-7.9A5.5 5.5 0 0 1 16.7 9"/><circle cx="16.5" cy="16.5" r=".9" fill="currentColor"/></symbol>
  <symbol id="i-folder" viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></symbol>
  <symbol id="i-doc" viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 13h6M9 17h4"/></symbol>
  <symbol id="i-sheet" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M4 10h16M4 15h16M10 4v16"/></symbol>
  <symbol id="i-slide" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M12 16v4M8 20h8"/></symbol>
  <symbol id="i-image" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="9.5" r="1.6"/><path d="m4 17 4.5-4.5 3.5 3.5 3-2.5L20 18"/></symbol>
  <symbol id="i-video" viewBox="0 0 24 24"><rect x="3" y="5" width="13" height="14" rx="2"/><path d="m16 10 5-3v10l-5-3z"/></symbol>
  <symbol id="i-audio" viewBox="0 0 24 24"><path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/></symbol>
  <symbol id="i-pdf" viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 15h1.5a1.5 1.5 0 0 0 0-3H9v6"/></symbol>
  <symbol id="i-archive" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/></symbol>
  <symbol id="i-file" viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></symbol>
  <symbol id="i-eye" viewBox="0 0 24 24"><path d="M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12"/><circle cx="12" cy="12" r="2.6"/></symbol>
  <symbol id="i-download" viewBox="0 0 24 24"><path d="M12 4v11m0 0 4-4m-4 4-4-4"/><path d="M5 19h14"/></symbol>
  <symbol id="i-link" viewBox="0 0 24 24"><path d="M10 13a4 4 0 0 0 5.7.4l3-3A4 4 0 0 0 13 4.7l-1.4 1.4"/><path d="M14 11a4 4 0 0 0-5.7-.4l-3 3A4 4 0 0 0 11 19.3l1.4-1.4"/></symbol>
  <symbol id="i-pencil" viewBox="0 0 24 24"><path d="M4 20h4l10.5-10.5a2.1 2.1 0 0 0-3-3L5 17z"/><path d="M13.5 6.5 17 10"/></symbol>
  <symbol id="i-trash" viewBox="0 0 24 24"><path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13"/><path d="M10 11v6M14 11v6"/></symbol>
  <symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
  <symbol id="i-upload" viewBox="0 0 24 24"><path d="M12 20V9m0 0 4 4m-4-4-4 4"/><path d="M5 5h14"/></symbol>
  <symbol id="i-grid" viewBox="0 0 24 24"><rect x="4" y="4" width="7" height="7" rx="1.4"/><rect x="13" y="4" width="7" height="7" rx="1.4"/><rect x="4" y="13" width="7" height="7" rx="1.4"/><rect x="13" y="13" width="7" height="7" rx="1.4"/></symbol>
  <symbol id="i-list" viewBox="0 0 24 24"><path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/></symbol>
  <symbol id="i-refresh" viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-.6 4"/><path d="M20 5v6h-6"/></symbol>
  <symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/></symbol>
  <symbol id="i-chevron" viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></symbol>
  <symbol id="i-left" viewBox="0 0 24 24"><path d="m15 6-6 6 6 6"/></symbol>
  <symbol id="i-x" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></symbol>
  <symbol id="i-inbox" viewBox="0 0 24 24"><path d="M4 13h4l1.5 3h5L16 13h4"/><path d="M5.5 5h13l1.5 8v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-4z"/></symbol>
</svg>

<div id="progress"><div></div></div>
<div class="wrap">
  <header>
    <div class="brand"><svg class="i" style="width:23px;height:23px"><use href="#i-cloud"/></svg></div>
    <div style="min-width:0">
      <h1>\#(title)</h1>
      <div class="sub" id="summary">Wird geladen …</div>
    </div>
  </header>

  <div class="card">
    <div class="toolbar">
      <nav class="crumbs" id="crumbs"></nav>
      <span class="grow"></span>
      <label class="search"><svg class="i"><use href="#i-search"/></svg>
        <input id="search" type="search" placeholder="Suchen"></label>
      <select class="sort" id="sort" title="Sortierung">
        <option value="name">Name</option>
        <option value="date">Datum</option>
        <option value="size">Größe</option>
      </select>
      <div class="seg">
        <button id="vList" class="on" title="Liste"><svg class="i"><use href="#i-list"/></svg></button>
        <button id="vGrid" title="Kacheln"><svg class="i"><use href="#i-grid"/></svg></button>
      </div>
      <button class="btn ghost" id="refresh" title="Aktualisieren"><svg class="i"><use href="#i-refresh"/></svg></button>
      <span id="writeTools" style="display:none; gap:8px">
        <button class="btn" id="newBtn"><svg class="i"><use href="#i-plus"/></svg>Neu</button>
        <button class="btn primary" id="upload"><svg class="i"><use href="#i-upload"/></svg>Hochladen</button>
      </span>
      <input type="file" id="fileInput" multiple hidden>
    </div>
    <div id="list"><div class="state"><div class="spinner"></div>Lade Inhalt …</div></div>
  </div>

  <footer>Bereitgestellt mit <b>Spind</b> · Open-Source-Sync für die Hetzner Storage Box</footer>
</div>

<div class="menu" id="newMenu">
  <button data-kind="folder"><svg class="i"><use href="#i-folder"/></svg>Ordner</button>
  <button data-kind="odt"><svg class="i"><use href="#i-doc"/></svg>Textdokument</button>
  <button data-kind="ods"><svg class="i"><use href="#i-sheet"/></svg>Tabelle</button>
  <button data-kind="odp"><svg class="i"><use href="#i-slide"/></svg>Präsentation</button>
</div>

<div class="backdrop" id="dialogBack">
  <div class="dialog">
    <h3 id="dTitle"></h3><p id="dText"></p>
    <input id="dInput" type="text">
    <div class="buttons">
      <button class="btn" id="dCancel">Abbrechen</button>
      <button class="btn primary" id="dOk">OK</button>
    </div>
  </div>
</div>

<div id="drop"><div><svg class="i" style="width:20px;height:20px"><use href="#i-upload"/></svg>Zum Hochladen ablegen</div></div>

<div id="viewer">
  <div class="top">
    <span class="name" id="vName"></span><span class="grow"></span>
    <a class="btn" id="vDownload" download><svg class="i"><use href="#i-download"/></svg>Laden</a>
    <button class="btn" onclick="closeViewer()"><svg class="i"><use href="#i-x"/></svg></button>
  </div>
  <div class="body" id="vBody"></div>
  <button class="nav prev" onclick="step(-1)"><svg class="i"><use href="#i-left"/></svg></button>
  <button class="nav next" onclick="step(1)"><svg class="i"><use href="#i-chevron"/></svg></button>
</div>
<div id="toasts"></div>

<script>
/* The recipient's browser picks the language, not the sender's app. This page lies
   on the Storage Box as a finished file — there is no server that could read
   `Accept-Language`, and the recipient does not necessarily speak the language of
   whoever shared it anyway.
   German is the source: if a key is missing, the German sentence stands there. */
const DE = (navigator.language || "de").toLowerCase().startsWith("de");
const T = {
  "Wird geladen …": "Loading …",
  "Name": "Name",
  "Datum": "Date",
  "Größe": "Size",
  "Neu": "New",
  "Hochladen": "Upload",
  "Lade Inhalt …": "Loading the contents …",
  "Bereitgestellt mit": "Served with",
  "· Open-Source-Sync für die Hetzner Storage Box":
    "· open-source sync for the Hetzner Storage Box",
  "Ordner": "Folder",
  "Textdokument": "Text document",
  "Tabelle": "Spreadsheet",
  "Präsentation": "Presentation",
  "Abbrechen": "Cancel",
  "Zum Hochladen ablegen": "Drop here to upload",
  "Laden": "Download",
  "Vorschau nicht möglich": "No preview possible",
  "Keine Vorschau für": "No preview for",
  "Im Editor öffnen": "Open in the editor",
  "Herunterladen": "Download",
  "Nichts gefunden": "Nothing found",
  "Dieser Ordner ist leer": "This folder is empty",
  "Dateien hierher ziehen zum Hochladen": "Drag files here to upload",
  "Link kopieren": "Copy the link",
  "Link kopiert": "Link copied",
  "Kopieren nicht möglich": "Copying is not possible",
  "Löschen": "Delete",
  "Gelöscht": "Deleted",
  "Neuer Ordner": "New folder",
  "Name des Ordners:": "Name of the folder:",
  "Ordner angelegt": "Folder created",
  "Dokument angelegt": "Document created",
  "Download fehlgeschlagen": "The download failed",
  "Umbenennen fehlgeschlagen": "Renaming failed",
  "Löschen fehlgeschlagen": "Deleting failed",
  "Anlegen fehlgeschlagen": "Creating failed",
  "Editor ist für diese Freigabe nicht eingerichtet":
    "The editor is not set up for this share",
  "Diese Freigabe ist schreibgeschützt": "This share is read-only",
  "1 Ordner": "1 folder",
  "%@ Ordner": "%@ folders",
  "1 Datei": "1 file",
  "%@ Dateien": "%@ files",
  "gemeinsam bearbeitbar": "editable together",
  "nur Lesen": "read-only",
  "läuft am %@ ab": "expires on %@",
  "Vorschau": "Preview",
  "Umbenennen": "Rename",
  "Umbenannt": "Renamed",
  "Freigabe": "Share",
};
function t(s) { return DE ? s : (T[s] || s); }

/* German writes “3 Ordner” and “1 Ordner” the same way, English does not. Two keys
   instead of one, and the German one already reads correctly in both cases. */
function count(n, one, many) { return t(n === 1 ? one : many).replace("%@", n); }

/* The page's fixed text is translated once on load. A walk through the text nodes
   rather than markers in the markup: that keeps the HTML readable, and a new
   sentence stands out because it stays untranslated. */
function translatePage() {
  if (DE) return;
  document.documentElement.lang = "en";
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const key = n.nodeValue.trim();
    if (key && T[key]) n.nodeValue = n.nodeValue.replace(key, T[key]);
  }
  for (const el of document.querySelectorAll("[title]")) {
    el.title = t(el.title);
  }
}

const HIDDEN = [".spind-share.html", ".spind-share.json", ".spind-versions"];
const EDITABLE = ["odt","ods","odp","odg","doc","docx","xls","xlsx","ppt","pptx","rtf","txt","csv"];
const IMAGES = ["png","jpg","jpeg","gif","webp","svg","bmp"];
const VIDEO = ["mp4","mov","webm","m4v"];
const AUDIO = ["mp3","wav","m4a","aac","flac","ogg"];
const TEXT = ["txt","md","csv","json","xml","log","js","ts","swift","py","sh","yml","yaml","html","css"];

let manifest = null, live = false, dir = "", entries = [], view = "list";
let previewList = [], previewIndex = 0;
const AUTH = "\#(authorization)";
const blobCache = new Map();

/// Every request needs the header explicitly — see the Swift doc comment.
function authFetch(path, options) {
  const opts = Object.assign({}, options);
  opts.headers = Object.assign({}, opts.headers, AUTH ? { Authorization: AUTH } : {});
  if (!AUTH) opts.credentials = "include";
  return fetch(path, opts);
}

/// Loads a protected file as an object URL so <img>, <video> and
/// downloads work without the browser re-authenticating.
async function blobURL(path) {
  if (blobCache.has(path)) return blobCache.get(path);
  const res = await authFetch(url(path));
  if (!res.ok) throw new Error("HTTP " + res.status);
  const objectURL = URL.createObjectURL(await res.blob());
  blobCache.set(path, objectURL);
  return objectURL;
}

async function saveFile(path) {
  try {
    const href = await blobURL(path);
    const a = document.createElement("a");
    a.href = href; a.download = path.split("/").pop();
    document.body.appendChild(a); a.click(); a.remove();
  } catch (e) { toast(t("Download fehlgeschlagen") + " (" + e.message + ")", "err"); }
}

/// Thumbnails and previews are fetched with auth, then swapped in.
function hydrateImages(root) {
  (root || document).querySelectorAll("img[data-src]").forEach(async img => {
    const path = img.dataset.src;
    img.removeAttribute("data-src");
    try { img.src = await blobURL(path); } catch { img.remove(); }
  });
}

const ext = n => (n.split(".").pop() || "").toLowerCase();
const isEditable = n => EDITABLE.includes(ext(n));
const url = p => location.origin + "/" + p.split("/").map(encodeURIComponent).join("/");
const escHtml = s => String(s).replace(/[&<>"]/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;" }[c]));
const esc = s => String(s).replace(/\\/g, "\\\\").replace(/'/g, "\\'");
const fmtSize = b => {
  if (b == null || isNaN(b)) return "";
  const u = ["B","KB","MB","GB","TB"]; let i = 0, v = b;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return v.toFixed(v >= 10 || i === 0 ? 0 : 1) + " " + u[i];
};
const fmtDate = ms => {
  const d = new Date(ms);
  // `undefined` and not "de-DE": the date belongs to the reader. A recipient in
  // London should see “16 Sep 2026” and not “16. Sep. 2026”.
  return isNaN(d) ? "" : d.toLocaleDateString(undefined, { day:"2-digit", month:"short", year:"numeric" });
};
function kindOf(name) {
  const e = ext(name);
  if (IMAGES.includes(e)) return ["i-image","c-media"];
  if (VIDEO.includes(e)) return ["i-video","c-media"];
  if (AUDIO.includes(e)) return ["i-audio","c-media"];
  if (e === "pdf") return ["i-pdf","c-pdf"];
  if (["xls","xlsx","ods","numbers","csv"].includes(e)) return ["i-sheet","c-sheet"];
  if (["ppt","pptx","odp","key"].includes(e)) return ["i-slide","c-slide"];
  if (["doc","docx","odt","pages","rtf","txt","md"].includes(e)) return ["i-doc","c-doc"];
  if (["zip","rar","gz","7z","dmg","tar"].includes(e)) return ["i-archive","c-arch"];
  return ["i-file","c-gen"];
}
function toast(msg, kind) {
  const el = document.createElement("div");
  el.className = "toast " + (kind || "");
  el.textContent = msg;
  document.getElementById("toasts").appendChild(el);
  setTimeout(() => { el.style.opacity = "0"; setTimeout(() => el.remove(), 250); }, 3600);
}
const setProgress = f =>
  document.querySelector("#progress div").style.width = f == null ? "0" : Math.round(f * 100) + "%";

/* Dialog instead of window.prompt */
function ask(title, text, value, options) {
  return new Promise(resolve => {
    const back = document.getElementById("dialogBack");
    document.getElementById("dTitle").textContent = title;
    document.getElementById("dText").textContent = text || "";
    const input = document.getElementById("dInput");
    input.style.display = options === false ? "none" : "block";
    input.value = value || "";
    back.classList.add("on");
    setTimeout(() => { input.focus(); input.select(); }, 30);
    const done = result => {
      back.classList.remove("on");
      document.getElementById("dOk").onclick = null;
      document.getElementById("dCancel").onclick = null;
      input.onkeydown = null;
      resolve(result);
    };
    document.getElementById("dOk").onclick = () => done(options === false ? true : input.value.trim());
    document.getElementById("dCancel").onclick = () => done(null);
    input.onkeydown = ev => { if (ev.key === "Enter") done(input.value.trim()); };
  });
}

// ---------------------------------------------------------------- loading

async function boot() {
  // Before anything else: what is already on screen should not flash up in German
  // and then jump.
  translatePage();
  try {
    const res = await authFetch(location.origin + "/.spind-share.json?" + Date.now(),
      { cache:"no-store" });
    if (res.ok) manifest = await res.json();
  } catch (e) { /* manifest is optional when PROPFIND works */ }
  if (manifest && manifest.canEdit) {
    document.getElementById("writeTools").style.display = "inline-flex";
  }
  await load();
}

async function propfind(path) {
  const res = await authFetch(url(path) + (path ? "/" : ""), {
    method:"PROPFIND", headers:{ Depth:"1" },
    body:'<?xml version="1.0"?><propfind xmlns="DAV:"><prop><resourcetype/>' +
         "<getcontentlength/><getlastmodified/></prop></propfind>",
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  const doc = new DOMParser().parseFromString(await res.text(), "application/xml");
  const base = "/" + (path ? path.split("/").map(encodeURIComponent).join("/") + "/" : "");
  return [...doc.getElementsByTagNameNS("DAV:", "response")].map(r => {
    const href = r.getElementsByTagNameNS("DAV:", "href")[0]?.textContent || "";
    if (href.replace(/\/+$/, "") === base.replace(/\/+$/, "")) return null;
    const name = decodeURIComponent(href.replace(/\/+$/, "").split("/").pop());
    const mod = r.getElementsByTagNameNS("DAV:", "getlastmodified")[0]?.textContent;
    return {
      p: path ? path + "/" + name : name,
      d: r.getElementsByTagNameNS("DAV:", "collection").length > 0,
      s: parseInt(r.getElementsByTagNameNS("DAV:","getcontentlength")[0]?.textContent || "0"),
      m: mod ? new Date(mod).getTime() / 1000 : null,
    };
  }).filter(Boolean);
}

function fromManifest(path) {
  const prefix = path ? path + "/" : "";
  return (manifest?.entries || []).filter(e =>
    e.p.startsWith(prefix) && e.p.slice(prefix.length) && !e.p.slice(prefix.length).includes("/"));
}

async function load(target) {
  if (target !== undefined) dir = target;
  document.getElementById("list").innerHTML =
    '<div class="state"><div class="spinner"></div>Lade Inhalt …</div>';
  try { entries = await propfind(dir); live = true; }
  catch (e) { entries = fromManifest(dir); live = false; }
  entries = entries.filter(e => !HIDDEN.includes(e.p.split("/").pop()));
  render();
  const files = entries.filter(e => !e.d);
  const total = files.reduce((s, e) => s + (e.s || 0), 0);
  const folders = entries.length - files.length;
  const parts = [];
  if (folders) parts.push(count(folders, "1 Ordner", "%@ Ordner"));
  parts.push(count(files.length, "1 Datei", "%@ Dateien"));
  if (total) parts.push(fmtSize(total));
  parts.push(t(manifest?.canEdit ? "gemeinsam bearbeitbar" : "nur Lesen"));
  if (manifest?.expires) {
    const day = new Date(manifest.expires * 1000)
      .toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" });
    parts.push(t("läuft am %@ ab").replace("%@", day));
  }
  document.getElementById("summary").textContent = parts.join(" · ");
}

// ---------------------------------------------------------------- render

function sorted(list) {
  const mode = document.getElementById("sort").value;
  return [...list].sort((a, b) => (b.d - a.d) ||
    (mode === "size" ? (b.s || 0) - (a.s || 0)
     : mode === "date" ? (b.m || 0) - (a.m || 0)
     : a.p.localeCompare(b.p, "de")));
}

function visible() {
  const q = document.getElementById("search").value.trim().toLowerCase();
  if (!q) return sorted(entries);
  const pool = manifest && !live ? manifest.entries : entries;
  return sorted(pool.filter(e => !e.d && e.p.toLowerCase().includes(q)));
}

function editorLink(path) {
  if (!manifest?.editBase || !manifest?.shareToken) return null;
  return `${manifest.editBase}/edit?s=${encodeURIComponent(manifest.shareToken)}` +
         `&f=${encodeURIComponent(path)}`;
}

const iconMarkup = (name, isDir) => {
  if (isDir) return '<svg class="i c-folder"><use href="#i-folder"/></svg>';
  const [symbol, color] = kindOf(name);
  return `<svg class="i ${color}"><use href="#${symbol}"/></svg>`;
};

function render() {
  const list = document.getElementById("list");
  const items = visible();
  previewList = items.filter(e => !e.d);
  renderCrumbs();
  if (!items.length) {
    list.innerHTML = '<div class="state"><svg class="i"><use href="#i-inbox"/></svg><div>' +
      (document.getElementById("search").value ? t("Nichts gefunden") : t("Dieser Ordner ist leer")) +
      "</div>" + (manifest?.canEdit ? '<div style="font-size:13px;margin-top:4px;color:var(--faint)">' +
      t("Dateien hierher ziehen zum Hochladen") + "</div>" : "") + "</div>";
    return;
  }
  list.innerHTML = view === "grid" ? renderGrid(items) : renderList(items);
  hydrateImages(list);
}

function renderList(items) {
  return items.map(e => {
    const name = e.p.split("/").pop();
    const label = escHtml(document.getElementById("search").value.trim() ? e.p : name);
    if (e.d) {
      return `<a class="row" href="#" onclick="load('${esc(e.p)}');return false">
        <div class="ico">${iconMarkup(name, true)}</div>
        <div class="info"><div class="name">${label}</div><div class="meta">${t("Ordner")}</div></div>
        ${rowActions(e)}</a>`;
    }
    const link = isEditable(name) ? editorLink(e.p) : null;
    const isImg = IMAGES.includes(ext(name)) && ext(name) !== "svg";
    return `<div class="row">
      <div class="ico">${isImg ? `<img loading="lazy" data-src="${escHtml(e.p)}" alt="">` : iconMarkup(name, false)}</div>
      <div class="info"><div class="name">${label}</div>
        <div class="meta">${fmtSize(e.s)}${e.m ? '<span class="date"> · ' + fmtDate(e.m*1000) + "</span>" : ""}</div></div>
      ${link ? `<a class="edit" href="${link}" target="_blank">${manifest.canEdit ? "Bearbeiten" : "Ansehen"}</a>` : ""}
      ${rowActions(e)}</div>`;
  }).join("");
}

function renderGrid(items) {
  return '<div class="grid">' + items.map(e => {
    const name = e.p.split("/").pop();
    const isImg = !e.d && IMAGES.includes(ext(name)) && ext(name) !== "svg";
    const open = e.d ? `load('${esc(e.p)}')` : `openViewer('${esc(e.p)}')`;
    return `<div class="tile" onclick="${open}">
      <div class="thumb">${isImg ? `<img loading="lazy" data-src="${escHtml(e.p)}" alt="">` : iconMarkup(name, e.d)}</div>
      <div class="cap"><div class="name">${escHtml(name)}</div>
        <div class="meta">${e.d ? t("Ordner") : fmtSize(e.s)}</div></div></div>`;
  }).join("") + "</div>";
}

function act(icon, title, handler, danger) {
  return `<button class="act${danger ? " danger" : ""}" title="${title}" aria-label="${title}"
    onclick="event.stopPropagation();event.preventDefault();${handler}"><svg class="i"><use href="#${icon}"/></svg></button>`;
}

function rowActions(e) {
  const name = escHtml(e.p.split("/").pop());
  let html = '<div class="acts">';
  if (!e.d) {
    html += act("i-eye", t("Vorschau"), `openViewer('${esc(e.p)}')`);
    html += act("i-download", t("Herunterladen"), `saveFile('${esc(e.p)}')`);
  }
  html += act("i-link", t("Link kopieren"), `copyLink('${esc(e.p)}')`);
  if (manifest?.canEdit) {
    html += act("i-pencil", t("Umbenennen"), `rename('${esc(e.p)}')`);
    html += act("i-trash", t("Löschen"), `remove('${esc(e.p)}',${e.d})`, true);
  }
  return html + "</div>";
}

function renderCrumbs() {
  const parts = dir ? dir.split("/") : [];
  const sep = '<span class="sep"><svg class="i"><use href="#i-chevron"/></svg></span>';
  let html = `<a href="#" onclick="load('');return false">\#(title)</a>`;
  let acc = "";
  parts.forEach((part, i) => {
    acc = acc ? acc + "/" + part : part;
    html += sep + (i === parts.length - 1
      ? `<span class="here">${escHtml(part)}</span>`
      : `<a href="#" onclick="load('${esc(acc)}');return false">${escHtml(part)}</a>`);
  });
  document.getElementById("crumbs").innerHTML = html;
}

// ---------------------------------------------------------------- preview

async function openViewer(path) {
  previewIndex = Math.max(0, previewList.findIndex(e => e.p === path));
  await showPreview();
}

async function showPreview() {
  const item = previewList[previewIndex];
  if (!item) return;
  const name = item.p.split("/").pop();
  const body = document.getElementById("vBody");
  document.getElementById("vName").textContent = name;
  const dl = document.getElementById("vDownload");
  dl.onclick = ev => { ev.preventDefault(); saveFile(item.p); };
  document.getElementById("viewer").classList.add("on");
  const many = previewList.length > 1;
  document.querySelector(".nav.prev").style.display = many ? "grid" : "none";
  document.querySelector(".nav.next").style.display = many ? "grid" : "none";
  const e = ext(name);
  body.innerHTML = '<div class="spinner"></div>';
  if (IMAGES.includes(e) || VIDEO.includes(e) || AUDIO.includes(e) || e === "pdf") {
    try {
      const src = await blobURL(item.p);
      body.innerHTML = IMAGES.includes(e) ? `<img src="${src}" alt="${escHtml(name)}">`
        : VIDEO.includes(e) ? `<video src="${src}" controls autoplay></video>`
        : AUDIO.includes(e) ? `<audio src="${src}" controls autoplay style="width:min(560px,90vw)"></audio>`
        : `<iframe src="${src}"></iframe>`;
    } catch (err) { body.innerHTML = '<div class="state">' + t("Vorschau nicht möglich") + '</div>'; }
  }
  else if (TEXT.includes(e)) {
    try {
      const res = await authFetch(url(item.p));
      body.innerHTML = `<pre>${escHtml((await res.text()).slice(0, 200000))}</pre>`;
    } catch { body.innerHTML = '<div class="state">' + t("Vorschau nicht möglich") + '</div>'; }
  } else {
    const link = isEditable(name) ? editorLink(item.p) : null;
    body.innerHTML = `<div class="state" style="color:#c9d3e0">${t("Keine Vorschau für")} .${escHtml(e)}<br><br>` +
      (link ? `<a class="btn primary" href="${link}" target="_blank">${t("Im Editor öffnen")}</a> ` : "") +
      `<button class="btn" onclick="saveFile('${esc(item.p)}')">${t("Herunterladen")}</button></div>`;
  }
}

const step = d => { previewIndex = (previewIndex + d + previewList.length) % previewList.length; showPreview(); };
function closeViewer() {
  document.getElementById("viewer").classList.remove("on");
  document.getElementById("vBody").innerHTML = "";
}

// ---------------------------------------------------------------- actions

async function copyLink(path) {
  try { await navigator.clipboard.writeText(url(path)); toast(t("Link kopiert"), "ok"); }
  catch { toast(t("Kopieren nicht möglich"), "err"); }
}

async function dav(method, path, headers) {
  const res = await authFetch(url(path), { method, headers: headers || {} });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res;
}

async function rename(path) {
  const old = path.split("/").pop();
  const next = await ask("Umbenennen", `„${old}" umbenennen in:`, old);
  if (!next || next === old) return;
  try {
    await dav("MOVE", path, { Destination: url((dir ? dir + "/" : "") + next), Overwrite: "F" });
    toast(t("Umbenannt"), "ok"); load();
  } catch (e) { toast(t("Umbenennen fehlgeschlagen") + " (" + e.message + ")", "err"); }
}

async function remove(path, isDir) {
  const name = path.split("/").pop();
  const ok = await ask("Löschen", `„${name}" wirklich löschen? Das lässt sich hier nicht rückgängig machen.`, "", false);
  if (!ok) return;
  try { await dav("DELETE", path + (isDir ? "/" : "")); toast(t("Gelöscht"), "ok"); load(); }
  catch (e) { toast(t("Löschen fehlgeschlagen") + " (" + e.message + ")", "err"); }
}

async function newFolder() {
  const name = await ask(t("Neuer Ordner"), t("Name des Ordners:"), t("Neuer Ordner"));
  if (!name) return;
  try { await dav("MKCOL", (dir ? dir + "/" : "") + name + "/"); toast(t("Ordner angelegt"), "ok"); load(); }
  catch (e) { toast(t("Anlegen fehlgeschlagen") + " (" + e.message + ")", "err"); }
}

async function newDocument(kind) {
  if (!manifest?.shareToken || !manifest?.editBase) {
    toast(t("Editor ist für diese Freigabe nicht eingerichtet"), "err"); return;
  }
  const labels = { odt:t("Textdokument"), ods:t("Tabelle"), odp:t("Präsentation") };
  const name = await ask(`Neue${kind === "ods" ? "" : "s"} ${labels[kind]}`, "Dateiname:",
    `${labels[kind]}.${kind}`);
  if (!name) return;
  const path = (dir ? dir + "/" : "") + name;
  try {
    const res = await fetch(`${manifest.editBase}/new?s=${encodeURIComponent(manifest.shareToken)}` +
      `&f=${encodeURIComponent(path)}&kind=${kind}`, { method:"POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || res.status);
    window.open(data.editUrl, "_blank");
    toast(t("Dokument angelegt"), "ok");
    setTimeout(load, 700);
  } catch (e) { toast(t("Anlegen fehlgeschlagen") + " (" + e.message + ")", "err"); }
}

function uploadFiles(files) {
  if (!manifest?.canEdit) { toast(t("Diese Freigabe ist schreibgeschützt"), "err"); return; }
  const queue = [...files];
  const total = queue.length;
  let done = 0;
  const next = () => {
    const file = queue.shift();
    if (!file) {
      setProgress(null);
      toast(done === total ? `${done} Datei${done === 1 ? "" : "en"} hochgeladen`
        : `${done} von ${total} hochgeladen`, done === total ? "ok" : "err");
      load(); return;
    }
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", url((dir ? dir + "/" : "") + file.name), true);
    if (AUTH) xhr.setRequestHeader("Authorization", AUTH); else xhr.withCredentials = true;
    xhr.upload.onprogress = ev => {
      if (ev.lengthComputable) setProgress((done + ev.loaded / ev.total) / total);
    };
    xhr.onload = () => {
      if (xhr.status < 400) done++; else toast(`${file.name}: HTTP ${xhr.status}`, "err");
      next();
    };
    xhr.onerror = () => { toast(`${file.name}: Netzwerkfehler`, "err"); next(); };
    xhr.send(file);
  };
  next();
}

// ---------------------------------------------------------------- wiring

document.getElementById("search").addEventListener("input", render);
document.getElementById("sort").addEventListener("change", render);
document.getElementById("refresh").addEventListener("click", () => load());
function setView(next) {
  view = next;
  document.getElementById("vList").classList.toggle("on", next === "list");
  document.getElementById("vGrid").classList.toggle("on", next === "grid");
  render();
}
document.getElementById("vList").addEventListener("click", () => setView("list"));
document.getElementById("vGrid").addEventListener("click", () => setView("grid"));

const newMenu = document.getElementById("newMenu");
document.getElementById("newBtn").addEventListener("click", ev => {
  const r = ev.currentTarget.getBoundingClientRect();
  newMenu.style.top = (r.bottom + window.scrollY + 6) + "px";
  newMenu.style.left = Math.max(8, r.left + window.scrollX - 60) + "px";
  newMenu.classList.toggle("on");
  ev.stopPropagation();
});
newMenu.querySelectorAll("button").forEach(b => b.addEventListener("click", () => {
  newMenu.classList.remove("on");
  const kind = b.dataset.kind;
  kind === "folder" ? newFolder() : newDocument(kind);
}));
document.addEventListener("click", () => newMenu.classList.remove("on"));

document.getElementById("upload").addEventListener("click", () => document.getElementById("fileInput").click());
document.getElementById("fileInput").addEventListener("change", ev => {
  uploadFiles(ev.target.files); ev.target.value = "";
});
["dragenter","dragover"].forEach(t => document.addEventListener(t, ev => {
  if (!manifest?.canEdit) return;
  ev.preventDefault(); document.getElementById("drop").classList.add("on");
}));
["dragleave","drop"].forEach(t => document.addEventListener(t, ev => {
  ev.preventDefault();
  if (t === "dragleave" && ev.relatedTarget) return;
  document.getElementById("drop").classList.remove("on");
  if (t === "drop" && ev.dataTransfer?.files?.length) uploadFiles(ev.dataTransfer.files);
}));
document.addEventListener("keydown", ev => {
  if (document.getElementById("viewer").classList.contains("on")) {
    if (ev.key === "Escape") closeViewer();
    if (ev.key === "ArrowLeft") step(-1);
    if (ev.key === "ArrowRight") step(1);
    return;
  }
  if (document.getElementById("dialogBack").classList.contains("on")) {
    if (ev.key === "Escape") document.getElementById("dCancel").click();
    return;
  }
  if (ev.key === "/" && document.activeElement.tagName !== "INPUT") {
    ev.preventDefault(); document.getElementById("search").focus();
  }
});
boot();
</script>
</body>
</html>
"""#
    }
}
