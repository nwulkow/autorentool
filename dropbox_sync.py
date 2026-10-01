"""Dropbox sync for the Mac/desktop app.

Mirrors the iOS app's DropboxClient.swift / DropboxSyncEngine.swift /
SidecarSyncEngine.swift at a protocol level (same App-folder-scoped REST
calls, same cursor-based list_folder pass, same conflict rules). Auth is
OAuth 2.0 + PKCE with `token_access_type=offline`, done once: the user opens
the authorize URL, Dropbox *shows* a code (no redirect_uri, so nothing to
register in the App Console), the user pastes it back. The refresh token
never expires; every sync exchanges it for a short-lived access token
(get_valid_access_token).

Three things sync through the same App folder, each with its own local
directory, remote subpath and index file:
  - books/         <-> App folder root   policy "keep-both"
  - chat_history/  <-> /ChatHistory      policy "merge" (union by message id)
  - digests/       <-> /Digests          policy "merge" (per chapter, newest wins)

NEVER-LOSE-DATA RULES (CLAUDE.md, "Never lose a book"). Every one of these
is load-bearing:
  * Change detection is by *content*, not by dirty flags: the local file's
    Dropbox content_hash is compared with the hash recorded at the last
    sync. A file that differs from what was last synced counts as "changed
    here" whatever the index says, so a lost dirty flag, a fresh index after
    reconnecting, or a file that does not parse is never overwritten.
  * Before sync overwrites or removes a local file it is snapshotted into
    backups/ (backups.py).
  * A book changed on both sides keeps both: the remote one becomes a new
    book titled "<title> - Dropbox conflict <stamp>".
  * Nothing is ever deleted on Dropbox. A book deleted in the app
    (mark_deleted) is *moved* to /Trash/ in the App folder. A tracked file
    that vanished locally without that mark is restored from Dropbox.
    Chat transcripts and digests never propagate deletion.
  * A remote deletion only removes a local book that is unchanged since the
    last sync (after snapshotting it); a locally changed one is re-uploaded.

Local state files live next to this one (all gitignored):
  .dropbox_app_key / .dropbox_refresh_token / .dropbox_access_token
  .dropbox_sync_index.json         books: {cursor, entries:{name:{rev,content_hash,dirty,deleted}}}
  .dropbox_chat_sync_index.json    the same, for chat_history/
  .dropbox_digest_sync_index.json  the same, for digests/
"""

import base64
import datetime
import hashlib
import json
import os
import secrets
from urllib.parse import quote as _urlquote

import requests

import backups

_HERE = os.path.dirname(os.path.abspath(__file__))
BOOKS_DIR = os.path.join(_HERE, "books")
CHAT_HISTORY_DIR = os.path.join(_HERE, "chat_history")
DIGESTS_DIR = os.path.join(_HERE, "digests")
APP_KEY_FILE = os.path.join(_HERE, ".dropbox_app_key")
REFRESH_TOKEN_FILE = os.path.join(_HERE, ".dropbox_refresh_token")
ACCESS_TOKEN_FILE = os.path.join(_HERE, ".dropbox_access_token")
INDEX_FILE = os.path.join(_HERE, ".dropbox_sync_index.json")
CHAT_INDEX_FILE = os.path.join(_HERE, ".dropbox_chat_sync_index.json")
DIGEST_INDEX_FILE = os.path.join(_HERE, ".dropbox_digest_sync_index.json")
TRASH_FOLDER = "/Trash"

# No redirect_uri: Dropbox's "no-redirect" code flow shows the authorization
# code on its own page for the user to copy, so nothing has to be registered
# in the App Console and nothing has to listen locally. (An earlier build sent
# http://localhost/dropbox_manual_redirect, which Dropbox rejects unless that
# exact URI was registered by hand — the connect flow failed silently there.)

API = "https://api.dropboxapi.com/2"
CONTENT_API = "https://content.dropboxapi.com/2"
OAUTH_AUTHORIZE_URL = "https://www.dropbox.com/oauth2/authorize"
OAUTH_TOKEN_URL = "https://api.dropboxapi.com/oauth2/token"


class DropboxAPIError(Exception):
    pass


class DropboxAuthError(Exception):
    pass


# ── simple plain-text file helpers ──────────────────────────────────────

def _read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = f.read().strip()
            return v or None
    except IOError:
        return None


def _write_file(path, value):
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)


def _remove_file(path):
    if os.path.exists(path):
        os.remove(path)


# ── app key storage ─────────────────────────────────────────────────────

def get_app_key():
    return _read_file(APP_KEY_FILE)


def set_app_key(app_key):
    app_key = (app_key or "").strip()
    if not app_key:
        _remove_file(APP_KEY_FILE)
        return
    _write_file(APP_KEY_FILE, app_key)


# ── refresh/access token storage ────────────────────────────────────────

def _get_refresh_token():
    return _read_file(REFRESH_TOKEN_FILE)


def _set_refresh_token(token):
    _write_file(REFRESH_TOKEN_FILE, token)


def _get_cached_access_token():
    """Returns (token, expiry_datetime) if a still-usable cached access
    token exists, else (None, None)."""
    try:
        with open(ACCESS_TOKEN_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        expiry = datetime.datetime.fromisoformat(data["expires_at"])
        return data["token"], expiry
    except (IOError, json.JSONDecodeError, KeyError, ValueError):
        return None, None


def _set_cached_access_token(token, expires_in):
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
        seconds=(expires_in or 14400)
    )
    with open(ACCESS_TOKEN_FILE, "w", encoding="utf-8") as f:
        json.dump({"token": token, "expires_at": expiry.isoformat()}, f)


def clear_token():
    _remove_file(APP_KEY_FILE)
    _remove_file(REFRESH_TOKEN_FILE)
    _remove_file(ACCESS_TOKEN_FILE)
    _remove_file(INDEX_FILE)
    _remove_file(CHAT_INDEX_FILE)
    _remove_file(DIGEST_INDEX_FILE)


def is_configured():
    return get_app_key() is not None and _get_refresh_token() is not None


# ── OAuth 2.0 + PKCE (mirrors DropboxAuthService.swift) ─────────────────

def build_authorize_url():
    """Starts the one-time auth flow: returns (authorize_url, code_verifier).
    Caller must hang on to code_verifier (server.py stashes it in memory)
    and pass it back into exchange_code_for_refresh_token along with the
    `code` the user pastes back after approving in the browser."""
    app_key = get_app_key()
    if not app_key:
        raise DropboxAuthError("No Dropbox App Key configured.")
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode("ascii").rstrip("=")
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode("ascii")).digest()
    ).decode("ascii").rstrip("=")
    params = {
        "client_id": app_key,
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "token_access_type": "offline",  # <- this is what earns us a refresh token
    }
    query = "&".join(f"{k}={_urlquote(str(v), safe='')}" for k, v in params.items())
    return f"{OAUTH_AUTHORIZE_URL}?{query}", verifier


def exchange_code_for_refresh_token(code, verifier):
    """Completes the one-time auth flow. `code` may be the bare
    authorization code Dropbox showed, or the full redirected URL it
    appears in (?code=...) — either is accepted so the user can just
    paste whatever they see."""
    app_key = get_app_key()
    if not app_key:
        raise DropboxAuthError("No Dropbox App Key configured.")
    code = _extract_code(code)
    resp = requests.post(OAUTH_TOKEN_URL, data={
        "code": code,
        "grant_type": "authorization_code",
        "client_id": app_key,
        "code_verifier": verifier,
    })
    if not (200 <= resp.status_code < 300):
        raise DropboxAuthError(f"Dropbox auth error {resp.status_code}: {resp.text}")
    data = resp.json()
    refresh_token = data.get("refresh_token")
    if not refresh_token:
        raise DropboxAuthError(
            "Dropbox didn't return a refresh token (expected with token_access_type=offline)."
        )
    _set_refresh_token(refresh_token)
    if data.get("access_token"):
        _set_cached_access_token(data["access_token"], data.get("expires_in"))


def _extract_code(raw):
    raw = (raw or "").strip()
    if "code=" in raw:
        # Pull the code= query param out of a pasted full URL.
        after = raw.split("code=", 1)[1]
        return after.split("&", 1)[0]
    return raw


def get_valid_access_token():
    """Returns a currently-valid access token, refreshing via the stored
    refresh token if the cached one is missing/expiring soon. This is what
    every API call below should use instead of a static token."""
    token, expiry = _get_cached_access_token()
    if token and expiry and expiry > _now_utc() + datetime.timedelta(seconds=60):
        return token
    return _refresh_access_token()


def _refresh_access_token():
    refresh_token = _get_refresh_token()
    app_key = get_app_key()
    if not refresh_token or not app_key:
        raise DropboxAuthError("Not connected to Dropbox.")
    resp = requests.post(OAUTH_TOKEN_URL, data={
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": app_key,
    })
    if not (200 <= resp.status_code < 300):
        raise DropboxAuthError(f"Dropbox token refresh failed {resp.status_code}: {resp.text}")
    data = resp.json()
    token = data["access_token"]
    _set_cached_access_token(token, data.get("expires_in"))
    return token


def _now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


# ── sync index (cursor + per-file rev/hash) ─────────────────────────────

def _load_index(index_file):
    try:
        with open(index_file, "r", encoding="utf-8") as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return {"cursor": None, "entries": {}}


def _save_index(index_file, index):
    with open(index_file, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2)


# ── low-level REST calls ────────────────────────────────────────────────

def _headers(token, extra=None):
    h = {"Authorization": f"Bearer {token}"}
    if extra:
        h.update(extra)
    return h


def _check(resp):
    if not (200 <= resp.status_code < 300):
        raise DropboxAPIError(f"Dropbox API error {resp.status_code}: {resp.text}")
    return resp


def _list_folder(token, folder=""):
    """`folder` is a Dropbox path relative to the App folder root, e.g.
    "" for the root (books) or "/ChatHistory". A folder that doesn't exist
    remotely yet (nothing has been pushed there before) 409s with a
    path/not_found error tag — Dropbox's convention for endpoint-specific
    errors, not a transport failure — which callers treat as "empty"."""
    resp = _check(requests.post(
        f"{API}/files/list_folder", headers=_headers(token, {"Content-Type": "application/json"}),
        json={"path": folder, "recursive": False, "include_deleted": True},
    ))
    return resp.json()


def _list_folder_continue(token, cursor):
    resp = _check(requests.post(
        f"{API}/files/list_folder/continue", headers=_headers(token, {"Content-Type": "application/json"}),
        json={"cursor": cursor},
    ))
    return resp.json()


def _download(token, path):
    resp = _check(requests.post(
        f"{CONTENT_API}/files/download",
        headers=_headers(token, {"Dropbox-API-Arg": json.dumps({"path": path}, ensure_ascii=True)}),
    ))
    entry = json.loads(resp.headers["Dropbox-API-Result"])
    return resp.content, entry


def _upload(token, path, data, mode):
    arg = {"path": path, "mode": mode, "autorename": False, "mute": True, "strict_conflict": False}
    resp = _check(requests.post(
        f"{CONTENT_API}/files/upload",
        headers=_headers(token, {
            "Content-Type": "application/octet-stream",
            "Dropbox-API-Arg": json.dumps(arg, ensure_ascii=True),
        }),
        data=data,
    ))
    return resp.json()


def _move(token, from_path, to_path):
    """Server-side move with autorename, so a same-named file already in
    /Trash is never overwritten. A source already gone (409 not_found) is
    fine to ignore. This is the only way this module ever removes anything
    from Dropbox: there is deliberately no delete call."""
    resp = requests.post(
        f"{API}/files/move_v2", headers=_headers(token, {"Content-Type": "application/json"}),
        json={"from_path": from_path, "to_path": to_path, "autorename": True},
    )
    if resp.status_code != 200 and "not_found" not in resp.text:
        _check(resp)


def test_connection(token):
    """Cheap call to verify the token works; raises DropboxAPIError if not."""
    _list_folder(token)


def _atomic_write(path, data):
    """Write-to-temp-then-replace so a concurrent reader (e.g. server.py's
    _read_chat_history, running on the request-handling thread while this
    sync pass writes the same path) always sees either the old or the new
    complete file, never a partial one."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


# ── sync ─────────────────────────────────────────────────────────────────

def _safe_filename(title):
    """Must stay identical to server.py:_safe_filename and
    Book.sanitizedFilename (Swift) — see CLAUDE.md."""
    return "".join(c if c.isalnum() or c in (" ", "-", "_") else "_" for c in (title or "")).strip()


_HASH_BLOCK = 4 * 1024 * 1024


def content_hash(data):
    """Dropbox's content_hash: SHA-256 over the concatenated SHA-256 digests
    of each 4 MiB block. Lets us tell whether a local file is byte-identical
    to a Dropbox revision without downloading it."""
    h = hashlib.sha256()
    for i in range(0, len(data), _HASH_BLOCK):
        h.update(hashlib.sha256(data[i:i + _HASH_BLOCK]).digest())
    return h.hexdigest()


def _read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _merge_chat_messages(remote_data, local_data):
    """Union two chat transcripts by message id (local wins on an exact id
    clash, which shouldn't happen since ids are uuid4'd), sorted by date.
    Mirrors the iOS chat merge: nothing said in either conversation is lost."""
    remote_messages = _loads(remote_data, list)
    local_messages = _loads(local_data, list)
    if remote_messages is None or local_messages is None:
        return None
    # Messages without an id each get a unique fallback key instead of
    # colliding on `None` and silently keeping only the last one.
    by_id = {}
    for msg in remote_messages:
        by_id[msg.get("id") or f"_no_id_remote_{len(by_id)}"] = msg
    for msg in local_messages:
        by_id[msg.get("id") or f"_no_id_local_{len(by_id)}"] = msg
    merged = sorted(by_id.values(), key=lambda m: m.get("date") or "")
    return json.dumps(merged, ensure_ascii=False).encode("utf-8")


def _digest_time(digest):
    """A digest's last-touched time as an ISO-8601 string (string order ==
    time order for the `...Z` form both apps write)."""
    if not isinstance(digest, dict):
        return ""
    return digest.get("editedAt") or digest.get("generatedAt") or ""


def _merge_digests(remote_data, local_data):
    """Per-chapter merge of two digest sidecars ({chapterId: digest}): the
    union of chapters, and for a chapter present on both sides the more
    recently generated/edited one. Mirrors SidecarSyncEngine.mergeDigests."""
    remote, local = _loads(remote_data, dict), _loads(local_data, dict)
    if remote is None or local is None:
        return None
    merged = dict(remote)
    for chapter_id, digest in local.items():
        other = merged.get(chapter_id)
        if other is None or _digest_time(digest) >= _digest_time(other):
            merged[chapter_id] = digest
    return json.dumps(merged, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")


def _loads(data, kind):
    """Parsed `data` if it is a `kind`, an empty `kind` for no data, and
    None when it is there but unreadable — merges must not mistake an
    unreadable file for an empty one and silently drop its content."""
    if not data:
        return kind()
    try:
        value = json.loads(data)
    except (ValueError, TypeError):
        return None
    return value if isinstance(value, kind) else None


def _merge_or_preserve(folder, name, remote, local_path, local_data):
    """Merges remote into local; returns the bytes now on disk locally. When
    either side can't be parsed, local is kept as is and the remote bytes go
    to backups/ instead of being lost in an overwrite."""
    backups.snapshot(local_path, folder["kind"], "before merge")
    merged = folder["merge"](remote, local_data)
    if merged is None:
        backups.store_bytes(remote, folder["kind"], name[:-5], "unmergeable remote")
        return local_data
    _atomic_write(local_path, merged)
    return merged


_FOLDERS = [
    {"local_dir": BOOKS_DIR, "remote": "", "index_file": INDEX_FILE,
     "policy": "keep-both", "merge": None, "kind": "books"},
    {"local_dir": CHAT_HISTORY_DIR, "remote": "/ChatHistory", "index_file": CHAT_INDEX_FILE,
     "policy": "merge", "merge": _merge_chat_messages, "kind": "chat_history"},
    {"local_dir": DIGESTS_DIR, "remote": "/Digests", "index_file": DIGEST_INDEX_FILE,
     "policy": "merge", "merge": _merge_digests, "kind": "digests"},
]


def sync():
    """Two-way sync of books/, chat_history/ and digests/, each against its
    own index. Returns {status, conflicts: [book filenames]} — only book
    conflicts need the user's attention; sidecars merge automatically."""
    if not is_configured():
        raise DropboxAPIError("Not connected to Dropbox.")
    token = get_valid_access_token()
    conflicts = []
    for folder in _FOLDERS:
        os.makedirs(folder["local_dir"], exist_ok=True)
        index = _load_index(folder["index_file"])
        try:
            conflicts += _pull_remote_changes(token, index, folder)
            _push_local_changes(token, index, folder)
        finally:
            # Whatever was done before a failure is real (files written,
            # uploads landed) and must be remembered; the cursor itself only
            # advances once a whole pull batch succeeded.
            _save_index(folder["index_file"], index)
    return {"status": "ok", "conflicts": conflicts}


def _local_files(local_dir):
    return {f for f in os.listdir(local_dir) if f.endswith(".json")}


def _remote_path(folder, name):
    return f"{folder['remote']}/{name}" if folder["remote"] else "/" + name


def _list_changes(token, folder, cursor):
    """All entries since `cursor` (or a full listing), plus the new cursor.
    An expired cursor (409 reset) falls back to a full listing — safe,
    because every decision below is made from content hashes."""
    try:
        result = _list_folder_continue(token, cursor) if cursor else _list_folder(token, folder["remote"])
    except DropboxAPIError as e:
        msg = str(e)
        if cursor and "reset" in msg:
            return _list_changes(token, folder, None)
        if folder["remote"] and "path/not_found" in msg:
            return [], None  # nothing pushed to this subfolder yet
        raise
    entries = list(result.get("entries", []))
    while result.get("has_more"):
        result = _list_folder_continue(token, result["cursor"])
        entries += result.get("entries", [])
    return entries, result.get("cursor")


def _remote_is_newer(entry, local_path):
    """For a file never synced on this device: is the Dropbox copy newer
    than the local one? Decides which side keeps the main name."""
    try:
        remote = datetime.datetime.fromisoformat(entry["server_modified"].replace("Z", "+00:00"))
        local = datetime.datetime.fromtimestamp(os.path.getmtime(local_path), datetime.timezone.utc)
    except (KeyError, ValueError, OSError, AttributeError):
        return False
    return remote > local


def _write_conflict_copy(local_dir, name, data, label="Dropbox conflict"):
    """Stores the remote side of a book conflict as a *separate book*: the
    title inside is changed too, so both apps list it as its own entry
    (same title + different filename would make iOS hide it and make the web
    app save it over the original)."""
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H-%M-%S")
    book = _loads(data, dict)
    if book is not None:
        book["title"] = f"{book.get('title') or name[:-5]} - {label} {stamp}"
        base = _safe_filename(book["title"])
        payload = json.dumps(book, indent=4, ensure_ascii=False).encode("utf-8")
    else:
        base = _safe_filename(f"{name[:-5]} - {label} {stamp}")
        payload = data
    dest = os.path.join(local_dir, base + ".json")
    n = 2
    while os.path.exists(dest):
        dest = os.path.join(local_dir, f"{base} {n}.json")
        n += 1
    _atomic_write(dest, payload)
    return os.path.basename(dest)


def _pull_remote_changes(token, index, folder):
    local_dir, kind = folder["local_dir"], folder["kind"]
    entries, cursor = _list_changes(token, folder, index.get("cursor"))
    records = index.setdefault("entries", {})
    conflicts = []

    for entry in entries:
        name = entry.get("name", "")
        if not name.endswith(".json"):
            continue
        tag = entry.get(".tag")
        local_path = os.path.join(local_dir, name)
        record = records.get(name)
        local_data = _read_bytes(local_path)
        local_hash = content_hash(local_data) if local_data is not None else None
        # "Changed here" is judged from bytes, not from the dirty flag: a file
        # we have no record of, or whose content differs from what was last
        # synced, holds something Dropbox may not have.
        changed_here = local_data is not None and (record is None or record.get("content_hash") != local_hash)

        if tag == "deleted":
            if record is None:
                continue
            if folder["policy"] != "keep-both" or local_data is None:
                records.pop(name, None)  # sidecars never delete locally
                continue
            if changed_here:
                # Edited here since the other device deleted it: keep it and
                # upload it again as a new file.
                records[name] = {"rev": None, "content_hash": None, "dirty": True}
                continue
            backups.snapshot(local_path, kind, "deleted on other device")
            os.remove(local_path)
            records.pop(name, None)
            continue

        if tag != "file":
            continue
        remote_hash = entry.get("content_hash")
        if local_hash == remote_hash:
            records[name] = {"rev": entry.get("rev"), "content_hash": remote_hash, "dirty": False}
            continue
        if record is not None and record.get("content_hash") == remote_hash:
            continue  # remote unchanged since last sync; push handles any local edit

        data, downloaded = _download(token, _remote_path(folder, name))
        new_record = {"rev": downloaded.get("rev"), "content_hash": downloaded.get("content_hash"), "dirty": False}
        if local_data is None:
            _atomic_write(local_path, data)
        elif not changed_here:
            backups.snapshot(local_path, kind, "before sync", routine=True)
            _atomic_write(local_path, data)
        elif folder["policy"] == "merge":
            _merge_or_preserve(folder, name, data, local_path, local_data)
            new_record["dirty"] = True  # merged copy goes back up over the rev just recorded
        elif record is None and _remote_is_newer(entry, local_path):
            # Never synced on this device (first connect) and Dropbox has the
            # newer version: that one keeps the main name, the local one
            # becomes a separate book. Both kept either way.
            _write_conflict_copy(local_dir, name, local_data, label="local conflict")
            backups.snapshot(local_path, kind, "before sync")
            _atomic_write(local_path, data)
            conflicts.append(name)
        else:
            # Changed on both sides: keep local as is, keep remote as a
            # separate book, then upload local over the now-known rev.
            _write_conflict_copy(local_dir, name, data)
            new_record["dirty"] = True
            conflicts.append(name)
        records[name] = new_record

    index["cursor"] = cursor
    return conflicts


def _upload_mode(record):
    if record and record.get("rev"):
        return {".tag": "update", "update": record["rev"]}
    return "add"


def _push_local_changes(token, index, folder):
    local_dir, kind = folder["local_dir"], folder["kind"]
    records = index.setdefault("entries", {})
    local_files = _local_files(local_dir)

    for name in sorted(local_files):
        local_path = os.path.join(local_dir, name)
        data = _read_bytes(local_path)
        if data is None:
            continue
        record = records.get(name)
        if record and record.get("content_hash") == content_hash(data) and record.get("rev"):
            record["dirty"] = False
            record.pop("deleted", None)
            continue  # Dropbox already has exactly these bytes
        remote_path = _remote_path(folder, name)
        try:
            uploaded = _upload(token, remote_path, data, _upload_mode(record))
        except DropboxAPIError as e:
            if "conflict" not in str(e):
                continue  # transient; still differs, so retried next pass
            # Dropbox holds a revision we never saw (e.g. a new local book
            # whose name already exists remotely). Same rules as a pull
            # conflict — never just overwrite it.
            remote, downloaded = _download(token, remote_path)
            if folder["policy"] == "merge":
                data = _merge_or_preserve(folder, name, remote, local_path, data)
            elif content_hash(remote) != content_hash(data):
                _write_conflict_copy(local_dir, name, remote)
            try:
                uploaded = _upload(token, remote_path, data, {".tag": "update", "update": downloaded["rev"]})
            except DropboxAPIError:
                records[name] = {"rev": downloaded.get("rev"), "content_hash": downloaded.get("content_hash"), "dirty": True}
                continue
        records[name] = {"rev": uploaded.get("rev"), "content_hash": uploaded.get("content_hash"), "dirty": False}

    # Tracked files that are gone locally.
    for name, record in list(records.items()):
        if name in local_files:
            continue
        remote_path = _remote_path(folder, name)
        if record.get("deleted"):
            # Deleted through the app (mark_deleted). Books are *moved* to
            # /Trash on Dropbox, never deleted; sidecars stay where they are.
            if folder["policy"] == "keep-both" and record.get("rev"):
                stamp = datetime.datetime.now().strftime("%Y-%m-%d %H-%M-%S")
                _move(token, remote_path, f"{TRASH_FOLDER}/{name[:-5]} (deleted {stamp}).json")
            records.pop(name, None)
        elif record.get("rev"):
            # Vanished without the app deleting it (Finder, a crash, a bad
            # tool): that is data loss, not intent — restore from Dropbox.
            try:
                data, downloaded = _download(token, remote_path)
            except DropboxAPIError as e:
                if "not_found" in str(e):
                    records.pop(name, None)  # gone on both sides
                continue  # anything else: keep the record, retry next pass
            _atomic_write(os.path.join(local_dir, name), data)
            records[name] = {"rev": downloaded.get("rev"), "content_hash": downloaded.get("content_hash"), "dirty": False}
        else:
            records.pop(name, None)


def mark_dirty(filename):
    """Call after server.py writes a book locally. Change detection is by
    content hash anyway; the flag just makes intent visible in the index."""
    _update_record(INDEX_FILE, filename, dirty=True, deleted=False)


def mark_chat_dirty(filename):
    _update_record(CHAT_INDEX_FILE, filename, dirty=True, deleted=False)


def mark_deleted(filename):
    """The app deleted (or renamed away from) this book on purpose. Only a
    file marked like this is moved to /Trash on Dropbox by the next push; a
    tracked file that disappears without the mark is restored instead."""
    _update_record(INDEX_FILE, filename, dirty=True, deleted=True)


def mark_chat_deleted(filename):
    _update_record(CHAT_INDEX_FILE, filename, dirty=True, deleted=True)


def mark_digest_deleted(filename):
    _update_record(DIGEST_INDEX_FILE, filename, dirty=True, deleted=True)


def _update_record(index_file, filename, **fields):
    index = _load_index(index_file)
    entries = index.setdefault("entries", {})
    record = entries.get(filename)
    if record is None:
        if fields.get("deleted"):
            return  # never synced — nothing on Dropbox to trash
        record = {}
    record.update(fields)
    entries[filename] = record
    _save_index(index_file, index)
