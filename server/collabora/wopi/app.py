# Spind — Copyright (C) 2026 Christoph Lindl-Guk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Spind WOPI bridge.

Collabora Online only renders documents — the content comes from a WOPI
host. This service is that host: it hands Collabora the file from a
Hetzner Storage Box share (WebDAV) and writes edits back.

Access is capability-based: every editor link carries an AES-GCM
encrypted token that contains the share host, its credentials, the file
path, write permission and an expiry. Without the shared secret (which
only Spind on the Mac and this service know) no token can be forged,
and a token only ever unlocks the one file it names.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.parse
import xml.etree.ElementTree as ET
from typing import Any

import httpx
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, Response

SECRET = base64.urlsafe_b64decode(os.environ["SPIND_WOPI_SECRET"])
COLLABORA_URL = os.environ.get("COLLABORA_URL", "http://collabora:9980").rstrip("/")
PUBLIC_URL = os.environ.get("PUBLIC_URL", "https://doc.example.de").rstrip("/")

app = FastAPI(title="Spind WOPI bridge", docs_url=None, redoc_url=None)

# Share pages live on the storage box and call this service cross-origin
# (e.g. to create a new document). Only those hosts may do so; the token
# in the request stays the actual capability.
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"https://[A-Za-z0-9\-]+\.your-storagebox\.de",
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

# In-memory WOPI locks: file token -> (lock id, expiry). Collabora is the
# only client, so this is enough to satisfy the protocol.
_locks: dict[str, tuple[str, float]] = {}
_discovery_cache: dict[str, Any] = {"fetched": 0.0, "actions": {}}


# --------------------------------------------------------------------------
# Tokens


def decode_token(token: str) -> dict:
    try:
        raw = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
        payload = json.loads(AESGCM(SECRET).decrypt(raw[:12], raw[12:], None))
    except Exception:
        raise HTTPException(status_code=401, detail="invalid token")
    if float(payload.get("e", 0)) < time.time():
        raise HTTPException(status_code=401, detail="token expired")
    return payload


def encode_token(payload: dict) -> str:
    nonce = os.urandom(12)
    blob = nonce + AESGCM(SECRET).encrypt(nonce, json.dumps(payload).encode(), None)
    return base64.urlsafe_b64encode(blob).decode().rstrip("=")


def file_url(payload: dict) -> str:
    path = "/".join(
        urllib.parse.quote(part) for part in payload["f"].split("/") if part
    )
    return f"https://{payload['h']}/{path}"


def auth_of(payload: dict) -> tuple[str, str]:
    return payload["u"], payload["p"]


# --------------------------------------------------------------------------
# Storage access


async def stat_file(payload: dict) -> tuple[int, str]:
    """Returns (size, version) for the shared file."""
    async with httpx.AsyncClient(timeout=20, follow_redirects=True) as client:
        response = await client.head(file_url(payload), auth=auth_of(payload))
    if response.status_code == 404:
        raise HTTPException(status_code=404, detail="file not found")
    if response.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"storage error {response.status_code}")
    size = int(response.headers.get("content-length", 0))
    version = response.headers.get("last-modified", str(size))
    return size, version


# --------------------------------------------------------------------------
# WOPI protocol


def session_identity(access_token: str, file_token: str) -> tuple[str, str]:
    """Identity of the person in this browser session.

    Everyone opens the same share link, so the file token is identical for
    all of them — the per-session token in access_token is what gives each
    participant their own cursor and name in Collabora.
    """
    if access_token and access_token != file_token:
        try:
            payload = decode_token(access_token)
            return payload.get("i", "guest"), payload.get("n", "Gast")
        except HTTPException:
            pass
    return "guest", "Gast"


@app.get("/wopi/files/{token}")
async def check_file_info(token: str, access_token: str = "") -> JSONResponse:
    payload = decode_token(token)
    size, version = await stat_file(payload)
    name = payload["f"].split("/")[-1]
    user_id, user_name = session_identity(access_token, token)
    return JSONResponse(
        {
            "BaseFileName": name,
            "Size": size,
            "Version": version,
            "OwnerId": "spind",
            "UserId": user_id,
            "UserFriendlyName": user_name,
            "UserCanWrite": bool(payload.get("w")),
            "UserCanNotWriteRelative": True,
            "SupportsUpdate": bool(payload.get("w")),
            "SupportsLocks": True,
            "SupportsGetLock": True,
            "DisablePrint": False,
            "HideUserList": "",
            "EnableOwnerTermination": False,
            "PostMessageOrigin": PUBLIC_URL,
        }
    )


@app.get("/wopi/files/{token}/contents")
async def get_file(token: str, access_token: str = "") -> Response:
    payload = decode_token(token)
    async with httpx.AsyncClient(timeout=120, follow_redirects=True) as client:
        response = await client.get(file_url(payload), auth=auth_of(payload))
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"storage error {response.status_code}")
    return Response(content=response.content, media_type="application/octet-stream")


@app.post("/wopi/files/{token}/contents")
async def put_file(token: str, request: Request, access_token: str = "") -> Response:
    payload = decode_token(token)
    if not payload.get("w"):
        raise HTTPException(status_code=404, detail="read-only share")
    body = await request.body()
    async with httpx.AsyncClient(timeout=180, follow_redirects=True) as client:
        response = await client.put(
            file_url(payload), auth=auth_of(payload), content=body
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"storage error {response.status_code}")
    _, version = await stat_file(payload)
    return Response(status_code=200, headers={"X-WOPI-ItemVersion": version})


@app.post("/wopi/files/{token}")
async def file_operation(token: str, request: Request, access_token: str = "") -> Response:
    """LOCK / UNLOCK / REFRESH_LOCK / GET_LOCK."""
    payload = decode_token(token)
    override = request.headers.get("X-WOPI-Override", "")
    lock = request.headers.get("X-WOPI-Lock", "")
    now = time.time()
    current = _locks.get(token)
    if current and current[1] < now:
        current = None
        _locks.pop(token, None)

    if override in ("LOCK", "REFRESH_LOCK"):
        if not payload.get("w"):
            raise HTTPException(status_code=404, detail="read-only share")
        if current and current[0] != lock and override == "LOCK":
            return Response(status_code=409, headers={"X-WOPI-Lock": current[0]})
        _locks[token] = (lock, now + 1800)
        return Response(status_code=200)
    if override == "UNLOCK":
        if current and current[0] != lock:
            return Response(status_code=409, headers={"X-WOPI-Lock": current[0]})
        _locks.pop(token, None)
        return Response(status_code=200)
    if override == "GET_LOCK":
        return Response(status_code=200, headers={"X-WOPI-Lock": current[0] if current else ""})
    return Response(status_code=501)


# --------------------------------------------------------------------------
# Editor page


async def editor_url_for(extension: str) -> str | None:
    """Looks up Collabora's editor URL for a file extension (cached)."""
    if time.time() - _discovery_cache["fetched"] > 3600:
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get(f"{COLLABORA_URL}/hosting/discovery")
        response.raise_for_status()
        actions: dict[str, str] = {}
        for app_node in ET.fromstring(response.text).iter("app"):
            for action in app_node.iter("action"):
                ext = action.get("ext")
                if ext and action.get("urlsrc"):
                    actions.setdefault(ext.lower(), action.get("urlsrc", ""))
        _discovery_cache.update({"fetched": time.time(), "actions": actions})
    return _discovery_cache["actions"].get(extension.lower())


def safe_relative(path: str) -> str:
    cleaned = path.strip().lstrip("/")
    parts = [p for p in cleaned.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise HTTPException(status_code=400, detail="ungültiger Pfad")
    if not parts:
        raise HTTPException(status_code=400, detail="leerer Pfad")
    return "/".join(parts)


def file_token_from_share(share_token: str, relative: str) -> str:
    """Derives a single-file token from a share-wide token.

    Share pages carry one token for the whole share, so files that were
    added after the page was generated (uploads, new documents) are
    editable too.
    """
    share = decode_token(share_token)
    payload = dict(share)
    payload["f"] = safe_relative(relative)
    payload["e"] = min(float(share.get("e", 0)), time.time() + 12 * 3600)
    return encode_token(payload)


@app.get("/edit", response_class=HTMLResponse)
async def edit(
    t: str = "", s: str = "", f: str = "", lang: str = "de-DE", name: str = ""
) -> HTMLResponse:
    if not t:
        if not (s and f):
            raise HTTPException(status_code=400, detail="Token fehlt")
        t = file_token_from_share(s, f)
    payload = decode_token(t)
    # Per-session identity: same document for everyone, own cursor each.
    session_token = encode_token(
        {
            "i": base64.urlsafe_b64encode(os.urandom(6)).decode().rstrip("="),
            "n": (name or payload.get("n") or "Gast")[:40],
            "e": time.time() + 12 * 3600,
        }
    )
    name = payload["f"].split("/")[-1]
    extension = name.rsplit(".", 1)[-1] if "." in name else ""
    urlsrc = await editor_url_for(extension)
    if not urlsrc:
        raise HTTPException(status_code=415, detail=f"Dateityp .{extension} wird nicht unterstützt")

    # Collabora builds its discovery URLs from the Host header of the
    # request — we ask from inside the container, but the browser needs
    # the public address.
    parts = urllib.parse.urlsplit(urlsrc)
    base = f"{PUBLIC_URL}{parts.path}?"
    if parts.query:
        base += f"{parts.query}&"

    wopi_src = f"{PUBLIC_URL}/wopi/files/{t}"
    action = (
        f"{base}WOPISrc={urllib.parse.quote(wopi_src, safe='')}"
        f"&lang={urllib.parse.quote(lang)}"
    )
    escaped_name = name.replace("<", "&lt;").replace("&", "&amp;")
    return HTMLResponse(
        f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{escaped_name} – Spind</title>
<style>
  html, body {{ margin:0; height:100%; background:#10151d;
    font:15px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }}
  #frame {{ position:fixed; inset:0; width:100%; height:100%; border:0; }}
  #boot {{ position:fixed; inset:0; display:grid; place-content:center center;
    gap:14px; justify-items:center; color:#8b98ad; }}
  .spin {{ width:26px; height:26px; border:3px solid rgba(255,255,255,.12);
    border-top-color:#2673f2; border-radius:50%; animation:s .8s linear infinite; }}
  @keyframes s {{ to {{ transform:rotate(360deg); }} }}
</style></head>
<body>
<div id="boot"><div class="spin"></div><div>„{escaped_name}“ wird geöffnet …</div></div>
<form id="f" action="{action}" method="post" target="frame">
  <input type="hidden" name="access_token" value="{session_token}">
</form>
<iframe id="frame" name="frame" allow="clipboard-read; clipboard-write; fullscreen"
        onload="document.getElementById('boot').style.display='none'"></iframe>
<script>document.getElementById('f').submit();</script>
</body></html>"""
    )


def empty_document(kind: str) -> bytes:
    """Smallest valid ODF document of the requested kind."""
    import io
    import zipfile

    bodies = {
        "odt": (
            "application/vnd.oasis.opendocument.text",
            "<office:body><office:text><text:p/></office:text></office:body>",
        ),
        "ods": (
            "application/vnd.oasis.opendocument.spreadsheet",
            "<office:body><office:spreadsheet><table:table table:name=\"Tabelle1\">"
            "<table:table-column/><table:table-row><table:table-cell/></table:table-row>"
            "</table:table></office:spreadsheet></office:body>",
        ),
        "odp": (
            "application/vnd.oasis.opendocument.presentation",
            "<office:body><office:presentation/></office:body>",
        ),
    }
    if kind not in bodies:
        raise HTTPException(status_code=400, detail=f"Typ .{kind} wird nicht unterstützt")
    mimetype, body = bodies[kind]
    content = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<office:document-content '
        'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
        'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
        'office:version="1.2">' + body + "</office:document-content>"
    )
    manifest = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<manifest:manifest '
        'xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" '
        'manifest:version="1.2">'
        f'<manifest:file-entry manifest:full-path="/" manifest:media-type="{mimetype}"/>'
        '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>'
        "</manifest:manifest>"
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("mimetype", mimetype, zipfile.ZIP_STORED)
        archive.writestr("content.xml", content)
        archive.writestr("META-INF/manifest.xml", manifest)
    return buffer.getvalue()


@app.post("/new")
async def new_document(s: str, f: str, kind: str = "odt") -> JSONResponse:
    """Creates an empty document inside a share and returns its editor URL."""
    share = decode_token(s)
    if not share.get("w"):
        raise HTTPException(status_code=403, detail="Freigabe ist schreibgeschützt")
    relative = safe_relative(f)
    payload = dict(share)
    payload["f"] = relative
    url = file_url(payload)
    async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
        existing = await client.head(url, auth=auth_of(payload))
        if existing.status_code < 400:
            raise HTTPException(status_code=409, detail="Datei existiert bereits")
        response = await client.put(
            url, auth=auth_of(payload), content=empty_document(kind)
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"storage error {response.status_code}")
    return JSONResponse({
        "path": relative,
        "editUrl": f"{PUBLIC_URL}/edit?s={urllib.parse.quote(s)}"
                   f"&f={urllib.parse.quote(relative)}",
    })


@app.get("/health", response_class=PlainTextResponse)
async def health() -> str:
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            response = await client.get(f"{COLLABORA_URL}/hosting/discovery")
        return "ok" if response.status_code == 200 else f"collabora {response.status_code}"
    except Exception as error:  # noqa: BLE001
        return f"collabora unreachable: {error}"
