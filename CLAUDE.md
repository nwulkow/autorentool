# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Be precise and save unnecessary words when you communicate or think.

## What this is

Autorino is a local-first writer's workbench: characters, relationships, locations, event-order
timelines, notes/questions, and a chapter text editor, with optional LLM assistance. It exists as
**two apps that share one on-disk format**:

- the original **web app** (Vue 3 from a CDN + a stdlib Python HTTP server) at the repo root, and
- a **native SwiftUI iOS app** in `ios/` (migration complete — see `docs/migration-architecture.md`).

Both read and write the *same* `books/<sanitized-title>.json` schema and sync through the *same*
Dropbox App folder. That byte-compatibility is the central constraint of this repo: a schema change
on one side that isn't mirrored on the other corrupts or silently drops data on the other.

## Running / building

### Web app (repo root)

```bash
./start.sh                 # macOS/Linux — :7001, kills any stale process on that port first
PORT=9000 ./start.sh       # custom port
python server.py 7001      # Windows / direct invocation
```

`start.sh` always runs `autorino_env/bin/python`, so that venv must have `google-genai`, `ollama`,
and `requests` installed (no `requirements.txt` — they're installed straight into `autorino_env`).
No build step, no lint, no test suite. `test_vue.js` is a stale scratch script that matches neither
the current `app.js` nor any workflow.

### iOS app (`ios/`)

```bash
cd ios
xcodegen generate    # REQUIRED after adding/removing any Swift file — project.yml is the source of truth
xcodebuild -project Autorino.xcodeproj -scheme Autorino \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Never hand-edit the generated `.xcodeproj`. There is no test target (the `AutorinoUITests` bundle
referenced in older transcripts was temporary scaffolding, removed) — verification is
`xcodebuild build` plus driving the app in the Simulator.

To confirm a change actually works rather than inferring it from source, use the `run` skill.

### Environment / secrets

- Web: `server.py` hand-parses `.env` at startup (`setdefault`, no `python-dotenv`). Only
  `GEMINI_API_KEY` is used; missing it breaks Gemini calls but nothing else.
- iOS: no `.env`. The Gemini API key and the Dropbox App key live in the **Keychain**
  (`Security/KeychainService.swift`), entered in Settings.

## The shared data format

`books/<sanitized-title>.json` is the contract between the two apps. Sanitization: keep
alphanumerics, space, `-`, `_`; replace everything else with `_`; strip surrounding whitespace.
It is implemented three times and **must stay identical** — `server.py:_safe_filename`,
`dropbox_sync.py`, and `Book.sanitizedFilename` in `ios/Autorino/Models/Book.swift`. A drift here
makes Dropbox sync fail to line up local and remote copies of the same book.

Adding a field to a book entity means touching **all** of:

1. `serializeBook` and `deserializeBook` in `app.js` (see below),
2. the matching `Codable` struct + `CodingKeys` in `ios/Autorino/Models/`,
3. `classes.py`'s `to_dict()` if the field should also reach LLM prompts.

Miss (1) and the field vanishes on web save/reload; miss (2) and it's dropped the next time the
phone writes that book.

**Decode leniently on the Swift side.** Swift models use hand-written `init(from:)` with
`decodeIfPresent` + defaults, deliberately: `BookStore.reload()` skips books that fail to decode
(`try?`), so one strict required field turns a real book *invisible* in the library rather than
raising an error. This already happened once (`Comment.rangeIndex`/`rangeLength`, which `app.js`
leaves `null`) and hid every book in `books/`.

### The camelCase ⟷ snake_case boundary (web only)

Frontend JS state is camelCase (`characterId`, `relationType`, `yPos`, `startText`); persisted JSON
is snake_case (`character_id`, `relation_type`, `y_pos`, `start_text`). Conversion happens in
exactly two places in `app.js`: `serializeBook(state)` (→ `POST /api/books/save`) and
`deserializeBook(data)` (← `GET /api/books`). The iOS side has no such boundary — its structs carry
explicit snake_case `CodingKeys`, so there is only one representation.

## Web app architecture

Three layers, no glue beyond `fetch` and JSON:

- **`index.html`** — loads Vue 3, Quill, docx/mammoth from CDNs, then `app.js`.
- **`app.js`** (~3300 lines) — the entire frontend: one Vue Options-API component with a single
  giant inline template string at the bottom. No components, no router, no build step. Navigate by
  the `/* ── Section ─── */` comment headers in `methods` (LLM, Passages, Characters, Canvas, Event
  orders, Locations, Notes, Text Editor, …) rather than searching blind.
- **`server.py`** — stdlib `http.server` subclass (`BookHandler`) serving static files plus
  `/api/*` JSON routes. Reads/writes `books/*.json` directly; delegates to `llm_utils.py` and
  `dropbox_sync.py`. Whatever the client POSTs is written almost as-is — `classes.py` does **not**
  validate it.
- **`classes.py`** — plain Python model classes with `to_dict()`, used server-side only for
  building LLM prompt text (e.g. `EventOrder.to_llm_prompt`).
- **`llm_utils.py`** — Gemini (`google-genai`, needs `GEMINI_API_KEY`) or a local Ollama server
  (auto-started by `start_ollama()`), chosen by whether `"gemini"` appears in the model name.
- **`dropbox_sync.py`** — OAuth 2.0 + PKCE with a long-lived refresh token, two-way sync of
  `books/` and `chat_history/` against the Dropbox App folder the iOS app uses. Credentials and
  sync cursors live in dotfiles at the repo root (`.dropbox_*`), all gitignored.

**Adding an API route:** add a branch in `do_GET`/`do_POST` matching on `urlparse(self.path).path`,
respond via `_json_response(code, payload)` (sets Content-Type + CORS). LLM routes must degrade
gracefully when `_LLM_AVAILABLE` is `False`; Dropbox routes likewise on `_DROPBOX_AVAILABLE`.

**Persistence details:** `app.js` autosaves every 10s (`_autosaveTimer` in `mounted()`) when
`dirty`, plus a `beforeunload` warning. LLM chat history is per-book at
`chat_history/<sanitized-title>.json` (written temp-then-`os.replace` so a concurrent Dropbox pull
can't be read half-written), unless the caller passes `persist:false` — the per-feature panes like
the event-order assistant keep their own in-memory history instead.

**Localization:** `I18N` near the top of `app.js` keyed by locale (`de`); `t(key)` falls back to the
English key itself. New user-facing strings go through `t(...)`.

## iOS app architecture

No embedded HTTP server, no `/api/*` equivalents — all of `server.py`'s routing is transport for a
browser and was deleted, not ported. Full writeup in `docs/migration-architecture.md`; practical
setup in `ios/README-iOS.md`.

```
AutorinoApp → AppEnvironment (composition root, @StateObject)
                ├─ BookStore              Documents/Books/*.json
                ├─ DropboxAuthService     OAuth PKCE, ASWebAuthenticationSession
                ├─ DropboxSyncEngine      books ⟷ Dropbox App folder
                ├─ ChatHistorySyncEngine  Documents/ChatHistory/*.json ⟷ /ChatHistory
                ├─ SyncStatus / SyncIndexStore
                └─ LLMService = GeminiLLMService   (URLSession → Gemini REST)
Views/ → BookEditor (ObservableObject wrapping one Codable Book, 1.5s debounced save)
```

- **Storage is plain `Codable` JSON files, not SwiftData** — chosen so Dropbox sync is a file diff
  rather than a translation layer with a second source of truth.
- **Gemini is the only LLM backend.** No Ollama, no FoundationModels, no on-device path — a
  confirmed non-goal, not a deferred phase.
- **Chapter `content` stays HTML on disk.** `Views/Editor/HTMLConversion.swift` converts to/from
  `NSAttributedString` at the view layer only, so a chapter edited on the phone still opens in the
  web app.
- **`.docx` is hand-rolled** in `Word/` (`ZipWriter`/`ZipReader`/`OOXMLDocumentParser`). iOS's
  `NSAttributedString` has no `.docx` document type (that's AppKit-only). Covers paragraphs/runs,
  headings, and blockquote indent — not tables, images, footnotes, or legacy binary `.doc`.
- **Pure logic lives outside views**: `TimelineMath`/`TimelineGeometry` (marker generation,
  `timeFromY`), `LocationTools` (tool tables, canvas sizing), `PromptBuilder` (ported from
  `classes.py`'s `to_llm_prompt`), `CSSColor` (parses *and re-emits* the CSS color strings in book
  JSON — writing `#rrggbb` back over an `rgba()` area fill would flatten a translucent lake to
  opaque in the web app).
- **Conflict policy differs by file type on purpose**: a conflicting book is preserved alongside as
  `<title> (Dropbox <timestamp>).json` (either side may hold irreplaceable prose); conflicting chat
  transcripts are *unioned* by message id (nothing is lost either way).

### Two iOS gotchas that already cost real time

- **A tab child's `.toolbar` never renders.** The single `NavigationStack` lives above
  `BookTabContainer`'s `TabView`, so only `BookTabContainer`'s own toolbar merges into the nav bar.
  Put per-tab controls in the view body (`AddBarButton`, `CanvasView.header`, `TimelineView.toolbar`
  computed property).
- **A custom font in `largeTitleTextAttributes` renders blank** through the appearance proxy on
  iOS 26 (inline titles are fine). Screens wanting a big serif heading draw one in their own
  content, as `BookListView` does.

### iOS localization

`ios/Autorino/Localizable.xcstrings` (en source + de); German reuses `app.js`'s `I18N` wording
wherever the English matches. Xcode auto-extracts literals passed directly to
`Text`/`Label`/`Button`/`.navigationTitle`/etc. It does **not** extract a literal that is a
ternary branch or an argument to a custom `String`-typed view parameter (e.g. `EmptyStateView`) —
those need an explicit `String(localized:)` wrap at the call site. Recent additions have also
needed adding to the catalog by hand; verify by decoding
`de.lproj/Localizable.strings` out of the built `.app` with `plutil -convert xml1`.

## Working in this repo

- **Migration rules still apply to further iOS work**: no literal line-by-line translation; preserve
  business behavior with idiomatic SwiftUI; read the corresponding `app.js`/`server.py` code before
  building a subsystem; don't migrate unrelated parts; prefer small independently testable steps.
- **Touch-vs-desktop divergences are deliberate**, not bugs to "fix": tap-to-place instead of
  drag-onto-canvas, an explicit Finish button instead of double-click-to-close an area, long-press
  before a drag so plain drags still pan a `ScrollView`, sheets instead of floating panes.
- `docs/` holds the architecture writeup; `ios/README-iOS.md` holds Dropbox/Gemini setup steps.
