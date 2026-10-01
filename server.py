#!/usr/bin/env python3
"""Lightweight backend for Autorino.

Serves static files and exposes two API endpoints:
  GET  /api/books      – return every book JSON stored in ./books/
  POST /api/books/save – persist a book JSON to ./books/<title>.json

Also exposes Dropbox sync routes (see dropbox_sync.py). Auth is OAuth 2.0 +
PKCE with a long-lived refresh token (mirrors the iOS app), done once:
  GET  /api/dropbox/status      – {available, configured, connected}
  POST /api/dropbox/app_key     – {appKey} -> store the Dropbox App Key
  POST /api/dropbox/auth_url    – {} -> {url} to open in a browser
  POST /api/dropbox/exchange    – {code} -> exchange for a refresh token
  POST /api/dropbox/disconnect  – forget all stored Dropbox credentials
  POST /api/dropbox/sync        – run a two-way sync pass now
"""

import json
import os
import glob
import sys
import threading
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Load .env file into environment variables before anything else
_env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
if os.path.exists(_env_path):
    with open(_env_path) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _k, _, _v = _line.partition("=")
                os.environ.setdefault(_k.strip(), _v.strip())

BOOKS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "books")
CHAT_HISTORY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chat_history")
DIGESTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "digests")

import backups  # noqa: E402 — the never-lose-data safety net, see backups.py


def _safe_filename(title):
    """Sanitize a book title into the filename both books/ and chat_history/
    use, so a chat transcript's filename always matches its book's, letting
    Dropbox sync key the two off the same name. Single source of truth for
    this rule — _save_book/_delete_book call this too rather than
    reimplementing it, so the two can't silently drift apart."""
    return "".join(c if c.isalnum() or c in (" ", "-", "_") else "_" for c in (title or "")).strip()


def _chat_history_path(book_title):
    return os.path.join(CHAT_HISTORY_DIR, f"{_safe_filename(book_title)}.json")


def _read_chat_history(book_title):
    try:
        with open(_chat_history_path(book_title), "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []


def _write_chat_history(book_title, history):
    os.makedirs(CHAT_HISTORY_DIR, exist_ok=True)
    dest = _chat_history_path(book_title)
    # Clearing or replacing a transcript drops turns: keep a copy first.
    old, ok = backups.load_json(dest)
    if not ok or (isinstance(old, list) and len(history) < len(old)):
        backups.snapshot(dest, "chat_history", "before replace")
    # Write-to-temp-then-replace so a concurrent reader (a chat POST landing
    # while dropbox_sync's background pull is writing this same path, see
    # dropbox_sync._pull_remote_changes) always sees either the old or the
    # new complete file, never a partial one that _read_chat_history's
    # broad except would otherwise silently treat as "empty" and overwrite.
    tmp = dest + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False)
    os.replace(tmp, dest)
    if _DROPBOX_AVAILABLE and dropbox_sync.is_configured():
        dropbox_sync.mark_chat_dirty(f"{_safe_filename(book_title)}.json")

# ── LLM helpers (import once; failures are non-fatal) ──────────────────────────
try:
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from llm_utils import (check_plausibility, custom_prompt_about_text, answer_to_prompt, start_ollama,
                           chat_custom_prompt, list_gemini_models, GEMINI_DEFAULT_MODEL, GEMINI_FALLBACK_MODELS)
    _LLM_AVAILABLE = True
except Exception as _e:
    _LLM_AVAILABLE = False
    print(f"[LLM] llm_utils not available: {_e}")

# ── Dropbox sync (import once; failures are non-fatal) ─────────────────────────
try:
    import dropbox_sync
    _DROPBOX_AVAILABLE = True
except Exception as _e:
    _DROPBOX_AVAILABLE = False
    print(f"[Dropbox] dropbox_sync not available: {_e}")

# In-flight PKCE code_verifier between /api/dropbox/auth_url and
# /api/dropbox/exchange. Single global is fine: this is a local single-user
# server and only one Dropbox connect flow is ever in progress at a time.
_dropbox_pending_verifier = None


def _get_ollama_models():
    """Return model names from a running (or just-started) ollama server."""
    try:
        import ollama
        start_ollama(url="http://127.0.0.1:11434/v1/models", cpu_only=False)
        result = ollama.list()
        # ollama.list() returns a ListResponse with a 'models' attribute
        models = result.models if hasattr(result, 'models') else result.get('models', [])
        names = []
        for m in models:
            name = m.model if hasattr(m, 'model') else m.get('name', '')
            if name:
                names.append(name)
        return names
    except Exception as e:
        print(f"[LLM] ollama list failed: {e}")
        return []


def _requested_fallbacks(data):
    """Fallback models for one LLM call. The client may name its own chain
    (`fallbacks`); otherwise the server's default alias chain is used. An
    explicit empty list means "no fallback, fail on my pick"."""
    fallbacks = data.get("fallbacks")
    if isinstance(fallbacks, list):
        return [m for m in fallbacks if isinstance(m, str) and m]
    return list(GEMINI_FALLBACK_MODELS) if _LLM_AVAILABLE else []


class BookHandler(SimpleHTTPRequestHandler):
    """Extend the simple static-file server with /api routes."""

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/books":
            self._send_books()
        elif path == "/api/llm/models":
            self._llm_models()
        elif path == "/api/llm/chat/history":
            self._llm_chat_history(parse_qs(parsed.query))
        elif path == "/api/dropbox/status":
            self._dropbox_status()
        elif path == "/api/digests":
            self._digests(parse_qs(parsed.query))
        elif path == "/api/backups":
            self._json_response(200, {"books": backups.list_book_backups()})
        else:
            super().do_GET()

    def end_headers(self):
        # Prevent browser from caching static files so edits are always picked up
        if not self.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/books/save":
            self._save_book()
        elif path == "/api/books/delete":
            self._delete_book()
        elif path == "/api/llm/prompt":
            self._llm_prompt()
        elif path == "/api/llm/chat":
            self._llm_chat()
        elif path == "/api/llm/chat/clear":
            self._llm_chat_clear()
        elif path == "/api/llm/chat/set":
            self._llm_chat_set()
        elif path == "/api/llm/chat/rename":
            self._llm_chat_rename()
        elif path == "/api/dropbox/app_key":
            self._dropbox_set_app_key()
        elif path == "/api/dropbox/auth_url":
            self._dropbox_auth_url()
        elif path == "/api/dropbox/exchange":
            self._dropbox_exchange()
        elif path == "/api/dropbox/disconnect":
            self._dropbox_disconnect()
        elif path == "/api/dropbox/sync":
            self._dropbox_sync()
        elif path == "/api/backups/restore":
            self._restore_backup()
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors_headers()
        self.end_headers()

    # ─── helpers ──────────────────────────────────────────────────────

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send_books(self):
        os.makedirs(BOOKS_DIR, exist_ok=True)
        books = []
        for fp in sorted(glob.glob(os.path.join(BOOKS_DIR, "*.json"))):
            try:
                with open(fp, "r", encoding="utf-8") as fh:
                    books.append(json.load(fh))
            except (json.JSONDecodeError, UnicodeDecodeError, IOError):
                # Not listed, but never lost: keep a copy where the restore
                # UI can find it, in case anything later writes this path.
                try:
                    backups.snapshot(fp, "books", "unreadable")
                except OSError:
                    pass
        body = json.dumps(books).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _save_book(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        os.makedirs(BOOKS_DIR, exist_ok=True)
        title = data.get("title", "untitled")
        safe = _safe_filename(title)
        dest = os.path.join(BOOKS_DIR, f"{safe}.json")
        # Snapshot the version about to be replaced. Always when the new one
        # lost content (an accidental chapter delete looks exactly like this)
        # or the old file doesn't parse; otherwise at most every 15 minutes.
        old, readable = backups.load_json(dest)
        try:
            if not readable:
                backups.snapshot(dest, "books", "unreadable")
            elif old is not None and backups.book_shrank(old, data):
                backups.snapshot(dest, "books", "before content removed")
            else:
                backups.snapshot(dest, "books", "autosave", routine=True)
        except OSError as e:
            if not readable or (old is not None and backups.book_shrank(old, data)):
                self._json_response(500, {"error": f"Could not back up the previous version, not saving: {e}"})
                return
            print(f"[backups] routine snapshot failed: {e}")
        # Temp-then-replace: a crash mid-write leaves the old file intact
        # instead of a truncated one.
        tmp = dest + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=4, ensure_ascii=False)
        os.replace(tmp, dest)
        if _DROPBOX_AVAILABLE and dropbox_sync.is_configured():
            dropbox_sync.mark_dirty(f"{safe}.json")
        body = json.dumps({"status": "ok", "path": dest}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _delete_book(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        title = data.get("title", "")
        safe = _safe_filename(title)
        dest = os.path.join(BOOKS_DIR, f"{safe}.json")
        try:
            backups.snapshot(dest, "books", "deleted")
            backups.snapshot(_chat_history_path(title), "chat_history", "deleted")
        except OSError as e:
            self._json_response(500, {"error": f"Could not back up the book, not deleting: {e}"})
            return
        if os.path.exists(dest):
            os.remove(dest)
            if _DROPBOX_AVAILABLE and dropbox_sync.is_configured():
                dropbox_sync.mark_deleted(f"{safe}.json")
        # Also remove any chat transcript still sitting under this title.
        # On a rename (save-under-new-title, then delete-old-title via this
        # route) app.js already moved the chat file via /api/llm/chat/rename
        # before calling this, so there's normally nothing left here to
        # remove — this is what makes a genuine book deletion (not just a
        # rename) clean up its chat history too, instead of leaving it
        # orphaned in chat_history/ and in Dropbox forever. Deletion of the
        # book file itself is picked up on the next sync pass by
        # _push_local_changes() diffing local files against tracked entries
        # — mark_deleted above moves it to /Trash on Dropbox on the next sync.
        chat_path = _chat_history_path(title)
        if os.path.exists(chat_path):
            os.remove(chat_path)
            if _DROPBOX_AVAILABLE and dropbox_sync.is_configured():
                dropbox_sync.mark_chat_deleted(os.path.basename(chat_path))
        body = json.dumps({"status": "ok"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _llm_models(self):
        """Return available LLM model names: gemini (live from the Gemini
        ListModels API, cached in llm_utils) + ollama. Deprecated generations
        (2.5 and below) and non-chat families (image/TTS/robotics/…) are
        filtered out in `list_gemini_models`."""
        models = ["gemini-flash-latest"]
        if _LLM_AVAILABLE:
            models = list_gemini_models() + _get_ollama_models()
        body = json.dumps(models).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _llm_prompt(self):
        """Run an LLM prompt. Body: {mode, text, custom_prompt, model}."""
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        if not _LLM_AVAILABLE:
            self._json_response(500, {"error": "llm_utils not available on server"})
            return
        mode = data.get("mode", "custom")          # 'plausibility' | 'custom'
        text = data.get("text", "")
        model = data.get("model", GEMINI_DEFAULT_MODEL)
        fallbacks = _requested_fallbacks(data)
        custom_prompt_text = data.get("custom_prompt", "")
        try:
            if mode == "plausibility":
                result, model_used = check_plausibility(text, model, fallbacks)
            else:
                result, model_used = custom_prompt_about_text(text, custom_prompt_text, model, fallbacks=fallbacks)
            self._json_response(200, {"result": result, "model_used": model_used})
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    def _llm_chat_history(self, query):
        book_title = (query.get("book") or [""])[0]
        self._json_response(200, {"history": _read_chat_history(book_title)})

    def _llm_chat_clear(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        book_title = data.get("book", "")
        _write_chat_history(book_title, [])
        self._json_response(200, {"status": "ok"})

    def _llm_chat_set(self):
        """Replace a book's live transcript wholesale. Body: {book, history}.
        This is what "Load chat" posts after picking a saved snapshot: the
        loaded turns have to become the on-disk history, or the next chat POST
        would read the old conversation back out of the file and continue
        that one instead."""
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        history = data.get("history", [])
        if not isinstance(history, list):
            self._json_response(400, {"error": "history must be a list"})
            return
        _write_chat_history(data.get("book", ""), history)
        self._json_response(200, {"status": "ok", "history": history})

    def _llm_chat_rename(self):
        """Move a chat transcript from one book title's file to another's,
        called right after a book rename succeeds (see commitTitleEdit in
        app.js) so chat history follows the book instead of being orphaned
        under the old title. Body: {old_title, new_title}."""
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        old_path = _chat_history_path(data.get("old_title", ""))
        new_path = _chat_history_path(data.get("new_title", ""))
        if os.path.exists(old_path) and old_path != new_path:
            os.makedirs(CHAT_HISTORY_DIR, exist_ok=True)
            backups.snapshot(new_path, "chat_history", "before rename")
            os.replace(old_path, new_path)
            if _DROPBOX_AVAILABLE and dropbox_sync.is_configured():
                dropbox_sync.mark_chat_dirty(os.path.basename(new_path))
        # The book's chapter digests follow it the same way. Copy, not move:
        # the old sidecar stays (digests never propagate deletion) and the
        # new one is picked up by the next sync as a new file.
        old_digest = os.path.join(DIGESTS_DIR, f"{_safe_filename(data.get('old_title', ''))}.json")
        new_digest = os.path.join(DIGESTS_DIR, f"{_safe_filename(data.get('new_title', ''))}.json")
        if os.path.exists(old_digest) and old_digest != new_digest and not os.path.exists(new_digest):
            with open(old_digest, "rb") as src:
                payload = src.read()
            with open(new_digest + ".tmp", "wb") as dst:
                dst.write(payload)
            os.replace(new_digest + ".tmp", new_digest)
        self._json_response(200, {"status": "ok"})

    def _llm_chat(self):
        """Multi-turn chat endpoint.
        Body: {text, custom_prompt, model, characters, book, include_book_text}."""
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        if not _LLM_AVAILABLE:
            self._json_response(500, {"error": "llm_utils not available on server"})
            return
        try:
            text = data.get("text", "")
            user_prompt = data.get("custom_prompt", "")
            model = data.get("model", GEMINI_DEFAULT_MODEL)
            fallbacks = _requested_fallbacks(data)
            characters_raw = data.get("characters", [])
            book_title = data.get("book", "")
            external_history = data.get("history", None)  # optional: caller manages history
            persist = data.get("persist", True)           # set False to skip disk read/write
            # "Include book text" off: drop the chapter/passage prose from the
            # prompt (characters still go through `characters`). Enforced here
            # as well as client-side so the flag recorded on the reply can't
            # disagree with what was actually sent.
            include_book_text = data.get("include_book_text", True)
            if not include_book_text:
                text = ""
            if not user_prompt.strip():
                self._json_response(400, {"error": "Empty prompt"})
                return
            from classes import Character
            characters = [Character(name=c.get("name", ""), description=c.get("description", "")) for c in characters_raw]
            if external_history is not None:
                history = external_history
            elif persist:
                history = _read_chat_history(book_title)
            else:
                history = []
            answer, model_used = chat_custom_prompt(text, user_prompt, model, history, characters, fallbacks)
            import datetime, uuid
            now = datetime.datetime.now(datetime.timezone.utc).isoformat()
            assistant_msg = {"id": str(uuid.uuid4()), "role": "assistant", "content": answer, "date": now}
            # Only stamped when the manuscript was left out — that's the case
            # the UI tags, and omitting the key otherwise keeps transcripts
            # written before this flag existed shaped exactly as they were.
            if not include_book_text:
                assistant_msg["used_book_text"] = False
            history = list(history) + [
                {"id": str(uuid.uuid4()), "role": "user", "content": user_prompt, "date": now},
                assistant_msg,
            ]
            if persist and external_history is None:
                _write_chat_history(book_title, history)
            # `model_used` is reported per response but deliberately not
            # written into the transcript: chat_history/*.json is shared
            # byte-for-byte with the iOS app, and a new message key there would
            # have to be mirrored in Swift and app.js first.
            self._json_response(200, {"result": answer, "history": history, "model_used": model_used})
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    def _digests(self, query):
        """Chapter digests for one book ({chapterId: digest}), generated on
        iOS and synced through /Digests. Read-only here."""
        title = (query.get("book") or [""])[0]
        path = os.path.join(DIGESTS_DIR, f"{_safe_filename(title)}.json")
        data, ok = backups.load_json(path)
        self._json_response(200, {"digests": data if ok and isinstance(data, dict) else {}})

    def _restore_backup(self):
        """Restores one book snapshot as a *new* book titled
        "<title> (restored <stamp>)", so restoring can never overwrite
        anything either. Body: {base, name}."""
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
            raw = backups.read_book_snapshot(data.get("base", ""), data.get("name", ""))
        except (ValueError, OSError) as e:
            self._json_response(400, {"error": str(e)})
            return
        try:
            book = json.loads(raw)
        except ValueError:
            book = None
        if not isinstance(book, dict):
            self._json_response(400, {"error": "This snapshot is not a readable book. The file is in backups/books/ for manual repair."})
            return
        stamp = data.get("name", "")[:19].replace(".", "-")
        book["title"] = f"{book.get('title') or data.get('base')} (restored {stamp})"
        dest = os.path.join(BOOKS_DIR, f"{_safe_filename(book['title'])}.json")
        if os.path.exists(dest):
            self._json_response(409, {"error": "Already restored."})
            return
        with open(dest + ".tmp", "w", encoding="utf-8") as fh:
            json.dump(book, fh, indent=4, ensure_ascii=False)
        os.replace(dest + ".tmp", dest)
        self._json_response(200, {"status": "ok", "title": book["title"]})

    def _dropbox_status(self):
        configured = _DROPBOX_AVAILABLE and dropbox_sync.is_configured()
        self._json_response(200, {
            "available": _DROPBOX_AVAILABLE,
            "configured": configured,
            # kept for older frontend builds that only look at "connected"
            "connected": configured,
        })

    def _dropbox_set_app_key(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        if not _DROPBOX_AVAILABLE:
            self._json_response(500, {"error": "dropbox_sync not available on server"})
            return
        app_key = (data.get("appKey") or "").strip()
        if not app_key:
            self._json_response(400, {"error": "App Key is required."})
            return
        dropbox_sync.set_app_key(app_key)
        self._json_response(200, {"status": "ok"})

    def _dropbox_auth_url(self):
        if not _DROPBOX_AVAILABLE:
            self._json_response(500, {"error": "dropbox_sync not available on server"})
            return
        try:
            url, verifier = dropbox_sync.build_authorize_url()
        except Exception as e:
            self._json_response(400, {"error": str(e)})
            return
        global _dropbox_pending_verifier
        _dropbox_pending_verifier = verifier
        self._json_response(200, {"url": url})

    def _dropbox_exchange(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return
        if not _DROPBOX_AVAILABLE:
            self._json_response(500, {"error": "dropbox_sync not available on server"})
            return
        code = data.get("code", "")
        verifier = _dropbox_pending_verifier
        if not verifier:
            self._json_response(400, {"error": "Start the connection again (Get authorization link) before pasting the code."})
            return
        try:
            dropbox_sync.exchange_code_for_refresh_token(code, verifier)
        except Exception as e:
            self._json_response(400, {"error": f"Could not connect to Dropbox: {e}"})
            return
        self._json_response(200, {"status": "ok"})

    def _dropbox_disconnect(self):
        if _DROPBOX_AVAILABLE:
            dropbox_sync.clear_token()
        self._json_response(200, {"status": "ok"})

    def _dropbox_sync(self):
        if not _DROPBOX_AVAILABLE:
            self._json_response(500, {"error": "dropbox_sync not available on server"})
            return
        if not dropbox_sync.is_configured():
            self._json_response(400, {"error": "Not connected to Dropbox."})
            return
        try:
            result = dropbox_sync.sync()
            self._json_response(200, result)
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    def _json_response(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Quieter logs – only print errors
        if args and str(args[0]).startswith(("4", "5")):
            super().log_message(fmt, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7001
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    server = HTTPServer(("127.0.0.1", port), BookHandler)
    print(f"\n  📚 Autorino")
    print(f"  http://localhost:{port}/index.html\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down…")
        server.shutdown()


if __name__ == "__main__":
    main()
