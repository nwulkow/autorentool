"""Dropbox sync for the Mac/desktop app.

Mirrors the iOS app's DropboxClient.swift / DropboxSyncEngine.swift at a
protocol level (same App-folder-scoped REST calls, same cursor-based
list_folder pass) so that content synced from the phone and from here
behaves the same way. Auth now also mirrors the iOS app
(DropboxAuthService.swift): OAuth 2.0 with PKCE and `token_access_type=
offline`, done once in a browser, yields a refresh token that does not
expire. Every sync exchanges it for a short-lived access token
automatically (see get_valid_access_token) — no manual re-auth. The
one-time step is done via the /api/dropbox/* routes in server.py, which
build the authorize URL and run the code/PKCE exchange server-side (no
browser redirect handler is needed here: the user just pastes back the
`code` Dropbox puts in the redirected URL after approving).

Two things are synced through the same App folder, each with its own
local directory, remote subpath, and index file (so the two passes never
share bookkeeping and can't step on each other):
  - books/         <-> App folder root   (BOOKS folder config below)
  - chat_history/   <-> /ChatHistory     (CHAT folder config below)

They deliberately use different conflict policies, matching the iOS engines
(DropboxSyncEngine.swift vs ChatHistorySyncEngine.swift): a book conflict
is preserved as a separate "<title> (Dropbox <date>).json" file because
either side could hold irreplaceable prose. A chat transcript is just a
list of timestamped, uniquely-id'd turns, so a conflict there is resolved
by unioning the two message lists by id instead — see _merge_chat_messages.

Local state files live next to this one (all gitignored):
  .dropbox_app_key              - the Dropbox App Key (OAuth client_id),
                                   plain text. Public identifier, not a
                                   secret (see DropboxConfig.swift).
  .dropbox_refresh_token         - long-lived refresh token, plain text.
  .dropbox_access_token          - current short-lived access token, plus
                                   its expiry, cached so we don't refresh
                                   on every single API call.
  .dropbox_sync_index.json  - books: per-file {rev, content_hash} + a
                               list_folder cursor, so repeat syncs are
                               incremental and conflict detection can tell
                               "changed since we last saw it" apart from
                               "we just wrote this".
  .dropbox_chat_sync_index.json - the same, for chat_history/.
"""

import base64
import datetime
import hashlib
import json
import os
import secrets
from urllib.parse import quote as _urlquote

import requests

_HERE = os.path.dirname(os.path.abspath(__file__))
BOOKS_DIR = os.path.join(_HERE, "books")
CHAT_HISTORY_DIR = os.path.join(_HERE, "chat_history")
APP_KEY_FILE = os.path.join(_HERE, ".dropbox_app_key")
REFRESH_TOKEN_FILE = os.path.join(_HERE, ".dropbox_refresh_token")
ACCESS_TOKEN_FILE = os.path.join(_HERE, ".dropbox_access_token")
INDEX_FILE = os.path.join(_HERE, ".dropbox_sync_index.json")
CHAT_INDEX_FILE = os.path.join(_HERE, ".dropbox_chat_sync_index.json")

# Any reserved, unique redirect URI works for the "manual copy-paste the
# code" flow below — it never has to actually be reachable, since Dropbox
# puts `code` in the URL itself and the user pastes that URL/code back
# rather than the browser following the redirect anywhere useful. Keep it
# distinct from the iOS app's own db-autorino scheme (different Dropbox
# app registrations use different redirect URIs) and register this exact
# URI in the Dropbox App Console -> Settings -> OAuth 2 -> Redirect URIs.
REDIRECT_URI = "http://localhost/dropbox_manual_redirect"

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
        "redirect_uri": REDIRECT_URI,
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
        "redirect_uri": REDIRECT_URI,
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

def sync():
    """Two-way sync of both BOOKS_DIR (-> App folder root) and
    CHAT_HISTORY_DIR (-> /ChatHistory), each against its own index.

    Returns a dict: {status, conflicts: [filenames]}. Only book conflicts
    are reported/named here — chat conflicts are resolved automatically by
    merge (see _merge_chat_messages) and never need caller attention.
    """
    if not is_configured():
        raise DropboxAPIError("Not connected to Dropbox.")
    token = get_valid_access_token()

    os.makedirs(BOOKS_DIR, exist_ok=True)
    os.makedirs(CHAT_HISTORY_DIR, exist_ok=True)

    book_index = _load_index(INDEX_FILE)
    conflicts = _pull_remote_changes(token, book_index, BOOKS_DIR, "", conflict_policy="keep-both")
    _push_local_changes(token, book_index, BOOKS_DIR, "")
    _save_index(INDEX_FILE, book_index)

    chat_index = _load_index(CHAT_INDEX_FILE)
    _pull_remote_changes(token, chat_index, CHAT_HISTORY_DIR, "/ChatHistory", conflict_policy="merge")
    _push_local_changes(token, chat_index, CHAT_HISTORY_DIR, "/ChatHistory")
    _save_index(CHAT_INDEX_FILE, chat_index)

    return {"status": "ok", "conflicts": conflicts}


def _local_files(local_dir):
    return {f for f in os.listdir(local_dir) if f.endswith(".json")}


def _merge_chat_messages(remote_data, local_path):
    """Union two chat transcripts by message id (local wins on an exact id
    clash, which shouldn't happen since ids are uuid4'd), sorted by date.
    Mirrors ChatHistorySyncEngine.mergeRemote on iOS: nothing said in
    either conversation is lost, and the merged transcript becomes the new
    synced state on both ends. Returns the merged bytes to write locally."""
    try:
        remote_messages = json.loads(remote_data)
    except (json.JSONDecodeError, TypeError):
        remote_messages = []
    try:
        with open(local_path, "r", encoding="utf-8") as f:
            local_messages = json.load(f)
    except (IOError, json.JSONDecodeError):
        local_messages = []

    # Messages without an id (shouldn't happen - ids are uuid4'd on write,
    # see server.py's _llm_chat - but guard anyway) each get a unique
    # fallback key instead of colliding on the same `None` key, which would
    # otherwise silently keep only the last such message and drop the rest.
    by_id = {}
    for msg in remote_messages:
        by_id[msg.get("id") or f"_no_id_remote_{len(by_id)}"] = msg
    for msg in local_messages:
        by_id[msg.get("id") or f"_no_id_local_{len(by_id)}"] = msg
    merged = sorted(by_id.values(), key=lambda m: m.get("date") or "")
    return json.dumps(merged, ensure_ascii=False).encode("utf-8")


def _pull_remote_changes(token, index, local_dir, remote_folder, conflict_policy):
    conflicts = []
    entries_seen = []
    cursor = index.get("cursor")
    try:
        result = _list_folder_continue(token, cursor) if cursor else _list_folder(token, remote_folder)
    except DropboxAPIError as e:
        if remote_folder and "path/not_found" in str(e):
            result = {"entries": [], "cursor": None, "has_more": False}  # folder never pushed to yet
        else:
            raise
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
        remote_path = f"{remote_folder}/{name}" if remote_folder else "/" + name

        if tag == "deleted":
            record = file_entries.get(name)
            if not record:
                continue  # never synced here, nothing to remove
            if record.get("dirty"):
                continue  # local edit in flight - next push resurrects it remotely
            local_path = os.path.join(local_dir, name)
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

        local_path = os.path.join(local_dir, name)
        local_dirty = record is not None and record.get("dirty") and os.path.exists(local_path)

        if local_dirty and conflict_policy == "merge":
            data, downloaded = _download(token, remote_path)
            merged = _merge_chat_messages(data, local_path)
            _atomic_write(local_path, merged)
            file_entries[name] = {
                "rev": downloaded.get("rev"),
                "content_hash": downloaded.get("content_hash"),
                "dirty": True,  # merged copy still needs to go back up over the rev just recorded
            }
        elif local_dirty:
            # Changed on both sides: preserve the remote copy, don't touch local.
            data, downloaded = _download(token, remote_path)
            base = name[:-5] if name.endswith(".json") else name
            stamp = _now_stamp()
            conflict_name = f"{base} (Dropbox {stamp}).json"
            _atomic_write(os.path.join(local_dir, conflict_name), data)
            file_entries[name] = {
                "rev": downloaded.get("rev"),
                "content_hash": downloaded.get("content_hash"),
                "dirty": True,  # keep dirty so the following push re-uploads over the now-known rev
            }
            conflicts.append(name)
        else:
            data, downloaded = _download(token, remote_path)
            _atomic_write(local_path, data)
            file_entries[name] = {
                "rev": downloaded.get("rev"),
                "content_hash": downloaded.get("content_hash"),
                "dirty": False,
            }

    return conflicts


def _push_local_changes(token, index, local_dir, remote_folder):
    file_entries = index.setdefault("entries", {})
    local_files = _local_files(local_dir)

    # New or changed local files (untracked, or tracked+dirty, or content
    # differs from what we last synced) get uploaded.
    for name in sorted(local_files):
        record = file_entries.get(name)
        local_path = os.path.join(local_dir, name)
        try:
            with open(local_path, "rb") as f:
                data = f.read()
        except IOError:
            continue

        needs_push = record is None or record.get("dirty") or record.get("content_hash") is None
        if not needs_push:
            continue

        remote_path = f"{remote_folder}/{name}" if remote_folder else "/" + name
        mode = {"update": record["rev"]} if (record and record.get("rev")) else "add"
        try:
            uploaded = _upload(token, remote_path, data, mode)
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
            remote_path = f"{remote_folder}/{name}" if remote_folder else "/" + name
            try:
                _delete(token, remote_path)
            except DropboxAPIError:
                pass
            file_entries.pop(name, None)


def mark_dirty(filename):
    """Call after server.py writes a book locally so the next sync knows
    to push it even if its content_hash happens to still match Dropbox's
    last-known value at some other layer (kept simple: always mark)."""
    _mark_dirty(INDEX_FILE, filename)


def mark_chat_dirty(filename):
    """Same as mark_dirty, for a chat transcript written to CHAT_HISTORY_DIR."""
    _mark_dirty(CHAT_INDEX_FILE, filename)


def _mark_dirty(index_file, filename):
    index = _load_index(index_file)
    entries = index.setdefault("entries", {})
    record = entries.get(filename, {})
    record["dirty"] = True
    entries[filename] = record
    _save_index(index_file, index)


def _now_stamp():
    import datetime
    return datetime.datetime.now().strftime("%Y-%m-%d %H.%M.%S")
