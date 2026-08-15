# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Autorino is a local-first writer's workbench: characters, relationships, locations, event-order
timelines, notes/questions, and a chapter text editor, with optional LLM assistance (Gemini or a
local Ollama model). No build step, no frontend package manager — Vue 3 loads from a CDN and the
whole UI lives in one file. Books are saved as plain JSON in `books/`.

## Running it

```bash
./start.sh                 # macOS/Linux — starts on :7001, kills any stale process on that port first
PORT=9000 ./start.sh       # custom port
python server.py 7001      # Windows / direct invocation (uses whatever `python` is on PATH)
```

Then open `http://localhost:<port>`. `start.sh` always runs the interpreter at
`autorino_env/bin/python`, so that venv must have `google-genai`, `ollama`, and `requests`
installed (there is no `requirements.txt` — these are just installed straight into
`autorino_env`). There is no separate lint/build/test command; there is no real automated test
suite (`test_vue.js` is a stale scratch script that no longer matches the current `app.js` export
shape and does not run as part of any workflow).

To verify a change actually works in the browser, use the `run` skill rather than guessing from
source reading alone.

### Environment

`server.py` hand-parses a `.env` file at startup (no `python-dotenv` dependency) and only sets
vars that aren't already set (`setdefault`). The only key in use is `GEMINI_API_KEY`. If it's
missing, Gemini calls fail but the rest of the app (and Ollama, if running locally) still works.

## Architecture

Three layers, no framework glue between them beyond `fetch` and JSON:

- **`index.html`** — loads Vue 3, Quill (rich text), docx/mammoth (Word export/import) from CDNs,
  then `app.js`.
- **`app.js`** (~2900 lines) — the entire frontend: one Vue Options-API component
  (`createApp({...}).mount('#app')`) with a single giant inline template string at the bottom of
  the file. There is no component decomposition, no router, no build step — everything is
  properties on one `data()`/`computed`/`methods` object. When editing the UI, find the relevant
  `methods` block by its `/* ── Section ─── */` comment header (LLM, Passages, Characters, Canvas,
  Event orders, Locations, Notes, Text Editor, etc.) rather than searching blind.
- **`server.py`** — stdlib-only `http.server` subclass (`BookHandler`) that serves static files
  and adds JSON API routes under `/api/*`. No framework, no ORM — every route reads/writes
  `books/*.json` directly or shells out to `llm_utils.py`.
- **`classes.py`** — plain Python model classes (`Book`, `Chapter`, `Character`, `Location`,
  `EventOrder`, `Event`, `Topic`, `Question`, …), each with a `to_dict()`. These are the
  server-side/LLM-prompt-building shape of a book; they are **not** used to validate what the
  frontend saves — `server.py` writes whatever JSON the client POSTs almost as-is.
- **`llm_utils.py`** — talks to either Gemini (`google-genai`, needs `GEMINI_API_KEY`) or a local
  Ollama server (auto-started via `start_ollama()` if not already running) depending on whether
  `"gemini"` appears in the requested model name.

### The camelCase ⟷ snake_case boundary

This is the thing most likely to bite you. Frontend JS state uses camelCase (`characterId`,
`relationType`, `yPos`, `startText`); persisted JSON / server payloads use snake_case
(`character_id`, `relation_type`, `y_pos`, `start_text`). The conversion happens in exactly two
places in `app.js`:

- `serializeBook(state)` — JS state → snake_case JSON sent to `POST /api/books/save`.
- `deserializeBook(data)` — snake_case JSON (loaded from `books/*.json` via `GET /api/books`) →
  JS state.

Any new field on a book entity needs to be added in both functions, or it will silently vanish on
save/reload. `classes.py`'s `to_dict()` methods are a second, independent snake_case shape used
only when building LLM prompt text server-side (e.g. `EventOrder.to_llm_prompt`) — keep it in mind
if you add a field that should also appear in what the LLM sees.

### State persistence

- Books are saved to `books/<sanitized-title>.json` (non-alphanumeric chars other to `- _`
  collapsed to `_`; see `_save_book`/`_delete_book` in `server.py` — the same sanitization must be
  used anywhere a book file is looked up by title).
- `app.js` autosaves every 10s (`_autosaveTimer` in `mounted()`) whenever `dirty` is true, plus a
  `beforeunload` warning.
- LLM chat history persists server-side at `/tmp/autorentool_chat_history.json` unless the caller
  passes `persist:false` (used by the per-feature chat panes like the event-order LLM assistant,
  which manage their own in-memory history instead).

### Adding an API route

Add a branch in `do_GET`/`do_POST` in `server.py`, matching on `urlparse(self.path).path`; write
the response with the existing `_json_response(code, payload)` helper for consistency (sets
`Content-Type` + CORS headers). LLM-backed routes should degrade gracefully when
`_LLM_AVAILABLE` is `False` (i.e. `llm_utils` failed to import) rather than raising.

### Localization

`I18N` near the top of `app.js` holds translation dicts keyed by locale (`de`); `t(key)` in
`methods` looks up the current `this.locale`, falling back to the English key itself when no
translation exists. New user-facing strings in templates should go through `t(...)`.



## Migration Strategy

This project is being migrated from Python + Vue.js to native Swift/iOS.

Do not perform a literal line-by-line translation.

Preserve business behavior, but follow idiomatic Swift and SwiftUI architecture.

Before implementing a major subsystem, understand the corresponding Python/Vue implementation and identify its responsibilities.

Do not migrate unrelated parts of the application.

Prefer small, independently testable migration steps.


## Docs
Folder docs contains documentation