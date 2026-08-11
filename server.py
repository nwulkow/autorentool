#!/usr/bin/env python3
"""Lightweight backend for Autorino.

Serves static files and exposes two API endpoints:
  GET  /api/books      – return every book JSON stored in ./books/
  POST /api/books/save – persist a book JSON to ./books/<title>.json
"""

import json
import os
import glob
import sys
import threading
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

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
CHAT_HISTORY_FILE = "/tmp/autorentool_chat_history.json"


def _read_chat_history():
    try:
        with open(CHAT_HISTORY_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []


def _write_chat_history(history):
    with open(CHAT_HISTORY_FILE, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False)

# ── LLM helpers (import once; failures are non-fatal) ──────────────────────────
try:
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from llm_utils import check_plausibility, custom_prompt_about_text, answer_to_prompt, start_ollama, chat_custom_prompt
    _LLM_AVAILABLE = True
except Exception as _e:
    _LLM_AVAILABLE = False
    print(f"[LLM] llm_utils not available: {_e}")


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


class BookHandler(SimpleHTTPRequestHandler):
    """Extend the simple static-file server with /api routes."""

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/books":
            self._send_books()
        elif path == "/api/llm/models":
            self._llm_models()
        elif path == "/api/llm/chat/history":
            self._llm_chat_history()
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
            history = []
            _write_chat_history(history)
            self._json_response(200, {"status": "ok"})
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
            except (json.JSONDecodeError, IOError):
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
        safe = "".join(
            c if c.isalnum() or c in (" ", "-", "_") else "_" for c in title
        ).strip()
        dest = os.path.join(BOOKS_DIR, f"{safe}.json")
        with open(dest, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=4, ensure_ascii=False)
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
        safe = "".join(
            c if c.isalnum() or c in (" ", "-", "_") else "_" for c in title
        ).strip()
        dest = os.path.join(BOOKS_DIR, f"{safe}.json")
        if os.path.exists(dest):
            os.remove(dest)
        body = json.dumps({"status": "ok"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _llm_models(self):
        """Return available LLM model names: gemini + ollama."""
        models = ["gemini-flash-latest"]
        if _LLM_AVAILABLE:
            models += _get_ollama_models()
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
        model = data.get("model", "gemini-flash-latest")
        custom_prompt_text = data.get("custom_prompt", "")
        try:
            if mode == "plausibility":
                result = check_plausibility(text, model)
            else:
                result = custom_prompt_about_text(text, custom_prompt_text, model)
            self._json_response(200, {"result": result})
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    def _llm_chat_history(self):
        self._json_response(200, {"history": _read_chat_history()})

    def _llm_chat(self):
        """Multi-turn chat endpoint. Body: {text, custom_prompt, model, characters}."""
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
            model = data.get("model", "gemini-flash-latest")
            characters_raw = data.get("characters", [])
            external_history = data.get("history", None)  # optional: caller manages history
            persist = data.get("persist", True)           # set False to skip disk read/write
            if not user_prompt.strip():
                self._json_response(400, {"error": "Empty prompt"})
                return
            from classes import Character
            characters = [Character(name=c.get("name", ""), description=c.get("description", "")) for c in characters_raw]
            if external_history is not None:
                history = external_history
            elif persist:
                history = _read_chat_history()
            else:
                history = []
            answer = chat_custom_prompt(text, user_prompt, model, history, characters)
            history = list(history) + [{"role": "user", "content": user_prompt}, {"role": "assistant", "content": answer}]
            if persist and external_history is None:
                _write_chat_history(history)
            self._json_response(200, {"result": answer, "history": history})
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
