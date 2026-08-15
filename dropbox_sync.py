"""Dropbox sync for the Mac/desktop app.

Mirrors the iOS app's DropboxClient.swift / DropboxSyncEngine.swift at a
protocol level (same App-folder-scoped REST calls, same cursor-based
list_folder pass, same "never silently drop a conflicting edit" policy) so
that a book synced from the phone and a book synced from here behave the
same way. Auth is simpler here on purpose: rather than an OAuth/PKCE flow
(this is a plain localhost server with no browser redirect handler and no
OS keychain to stash refresh tokens in), the user pastes a long-lived
access token generated in the Dropbox App Console (Settings -> OAuth 2 ->
"Generate access token"). See README's Dropbox section for the walkthrough.

Two small local state files live next to this one (both gitignored):
  .dropbox_token       - the access token, plain text
  .dropbox_sync_index.json - per-file {rev, content_hash} + a list_folder
                              cursor, so repeat syncs are incremental and
                              conflict detection can tell "changed since we
                              last saw it" apart from "we just wrote this".
"""

import json
import os

import requests

_HERE = os.path.dirname(os.path.abspath(__file__))
BOOKS_DIR = os.path.join(_HERE, "books")
TOKEN_FILE = os.path.join(_HERE, ".dropbox_token")
INDEX_FILE = os.path.join(_HERE, ".dropbox_sync_index.json")

API = "https://api.dropboxapi.com/2"
CONTENT_API = "https://content.dropboxapi.com/2"


class DropboxAPIError(Exception):
    pass


# ── token storage ───────────────────────────────────────────────────────

def get_token():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            t = f.read().strip()
            return t or None
    except IOError:
        return None


def set_token(token):
    token = (token or "").strip()
    if not token:
        clear_token()
        return
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(token)


def clear_token():
    if os.path.exists(TOKEN_FILE):
        os.remove(TOKEN_FILE)
    if os.path.exists(INDEX_FILE):
        os.remove(INDEX_FILE)


def is_configured():
    return get_token() is not None


# ── sync index (cursor + per-file rev/hash) ─────────────────────────────

def _load_index():
    try:
        with open(INDEX_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return {"cursor": None, "entries": {}}


def _save_index(index):
    with open(INDEX_FILE, "w", encoding="utf-8") as f:
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


def _list_folder(token):
    resp = _check(requests.post(
        f"{API}/files/list_folder", headers=_headers(token, {"Content-Type": "application/json"}),
        json={"path": "", "recursive": False, "include_deleted": True},
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


def _delete(token, path):
    resp = requests.post(
        f"{API}/files/delete_v2", headers=_headers(token, {"Content-Type": "application/json"}),
        json={"path": path},
    )
    # A file already gone on Dropbox's side (409 path_lookup/not_found) is fine to ignore.
    if resp.status_code not in (200,) and "not_found" not in resp.text:
        _check(resp)


def test_connection(token):
    """Cheap call to verify the token works; raises DropboxAPIError if not."""
    _list_folder(token)


# ── sync ─────────────────────────────────────────────────────────────────

def sync():
    """Two-way sync between BOOKS_DIR and the Dropbox App folder.

    Returns a dict: {status, synced_at, conflicts: [filenames]}.
    Policy mirrors the iOS engine: a file changed on both sides since the
    last sync is never silently overwritten. The remote copy is saved
    alongside as "<title> (Dropbox <timestamp>).json" and the conflict is
    reported back to the caller; the local edit then wins the shared
    filename on the following push.
    """
    token = get_token()
    if not token:
        raise DropboxAPIError("Not connected to Dropbox.")

    os.makedirs(BOOKS_DIR, exist_ok=True)
    index = _load_index()
    conflicts = []

    conflicts += _pull_remote_changes(token, index)
    _push_local_changes(token, index)
    _save_index(index)

    return {"status": "ok", "conflicts": conflicts}


def _local_files():
    return {f for f in os.listdir(BOOKS_DIR) if f.endswith(".json")}


def _pull_remote_changes(token, index):
    conflicts = []
    entries_seen = []
    cursor = index.get("cursor")
    result = _list_folder_continue(token, cursor) if cursor else _list_folder(token)
    entries_seen += result.get("entries", [])
    cursor = result.get("cursor")
    while result.get("has_more"):
        result = _list_folder_continue(token, cursor)
        entries_seen += result.get("entries", [])
        cursor = result.get("cursor")
    index["cursor"] = cursor

    file_entries = index.setdefault("entries", {})

    for entry in entries_seen:
        tag = entry.get(".tag")
        name = entry.get("name", "")
        if not name.endswith(".json"):
            continue

        if tag == "deleted":
            record = file_entries.get(name)
            if not record:
                continue  # never synced here, nothing to remove
            if record.get("dirty"):
                continue  # local edit in flight - next push resurrects it remotely
            local_path = os.path.join(BOOKS_DIR, name)
            if os.path.exists(local_path):
                os.remove(local_path)
            file_entries.pop(name, None)
            continue

        if tag != "file":
            continue

        content_hash = entry.get("content_hash")
        record = file_entries.get(name)
        if record and record.get("content_hash") == content_hash:
            continue  # already in sync

        local_path = os.path.join(BOOKS_DIR, name)
        local_dirty = record is not None and record.get("dirty") and os.path.exists(local_path)

        if local_dirty:
            # Changed on both sides: preserve the remote copy, don't touch local.
            data, downloaded = _download(token, "/" + name)
            base = name[:-5] if name.endswith(".json") else name
            stamp = _now_stamp()
            conflict_name = f"{base} (Dropbox {stamp}).json"
            with open(os.path.join(BOOKS_DIR, conflict_name), "wb") as f:
                f.write(data)
            file_entries[name] = {
                "rev": downloaded.get("rev"),
                "content_hash": downloaded.get("content_hash"),
                "dirty": True,  # keep dirty so the following push re-uploads over the now-known rev
            }
            conflicts.append(name)
        else:
            data, downloaded = _download(token, "/" + name)
            with open(local_path, "wb") as f:
                f.write(data)
            file_entries[name] = {
                "rev": downloaded.get("rev"),
                "content_hash": downloaded.get("content_hash"),
                "dirty": False,
            }

    return conflicts


def _push_local_changes(token, index):
    file_entries = index.setdefault("entries", {})
    local_files = _local_files()

    # New or changed local files (untracked, or tracked+dirty, or content
    # differs from what we last synced) get uploaded.
    for name in sorted(local_files):
        record = file_entries.get(name)
        local_path = os.path.join(BOOKS_DIR, name)
        try:
            with open(local_path, "rb") as f:
                data = f.read()
        except IOError:
            continue

        needs_push = record is None or record.get("dirty") or record.get("content_hash") is None
        if not needs_push:
            continue

        mode = {"update": record["rev"]} if (record and record.get("rev")) else "add"
        try:
            uploaded = _upload(token, "/" + name, data, mode)
        except DropboxAPIError:
            # Leave as dirty/untracked; retried on the next sync pass.
            continue
        file_entries[name] = {
            "rev": uploaded.get("rev"),
            "content_hash": uploaded.get("content_hash"),
            "dirty": False,
        }

    # Files we were tracking that no longer exist locally were deleted here.
    for name in list(file_entries.keys()):
        if name not in local_files:
            try:
                _delete(token, "/" + name)
            except DropboxAPIError:
                pass
            file_entries.pop(name, None)


def mark_dirty(filename):
    """Call after server.py writes a book locally so the next sync knows
    to push it even if its content_hash happens to still match Dropbox's
    last-known value at some other layer (kept simple: always mark)."""
    index = _load_index()
    entries = index.setdefault("entries", {})
    record = entries.get(filename, {})
    record["dirty"] = True
    entries[filename] = record
    _save_index(index)


def _now_stamp():
    import datetime
    return datetime.datetime.now().strftime("%Y-%m-%d %H.%M.%S")
