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
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

BOOKS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "books")


class BookHandler(SimpleHTTPRequestHandler):
    """Extend the simple static-file server with /api routes."""

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/books":
            self._send_books()
        else:
            super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/books/save":
            self._save_book()
        elif path == "/api/books/delete":
            self._delete_book()
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
