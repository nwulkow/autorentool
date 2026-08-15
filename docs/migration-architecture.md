# Migration Architecture: Autorino → Native iOS

Status: **phases 1–10 shipped** (see `ios/README-iOS.md` for exactly what's
built vs. deferred). Target: SwiftUI app, no Python/FastAPI backend, no
`http.server` JSON API. Source of truth for current behavior: `app.js` (Vue
Options API, ~2900 lines), `server.py` (stdlib HTTP handler), `classes.py`
(server-side model shape used for LLM prompts), `llm_utils.py` (Gemini/Ollama
calls).

Two decisions below were revised after this doc was first written, once
Dropbox sync between the iPhone and this Mac became an explicit
requirement rather than a stretch goal — see §3 and §8.

## 1. What today's architecture actually does

Today the "backend" is not a real service — it's a thin persistence + LLM-proxy
shim that exists only because a browser can't touch the filesystem or call an
LLM API directly (CORS/API-key exposure):

| Today (client ⇄ server) | Real responsibility | Only exists because of the browser? |
|---|---|---|
| `GET /api/books` / `POST /api/books/save` / `POST /api/books/delete` | Read/write `books/<title>.json` | Yes — file I/O |
| `GET /api/llm/models` | List Gemini + local Ollama models | Yes — Ollama process lives server-side |
| `POST /api/llm/prompt`, `POST /api/llm/chat`, `.../history`, `.../clear` | Call Gemini/Ollama, keep chat history | Yes — API key + Ollama socket |
| `serializeBook` / `deserializeBook` in `app.js` | camelCase (UI state) ⟷ snake_case (JSON on disk) boundary | No — pure data shaping |
| `classes.py` (`Book`, `Character`, `EventOrder.to_llm_prompt()`, …) | Build the text blob sent to the LLM | No — prompt formatting is business logic |
| Vue `data()` / `computed` / `methods` per tab | All actual UI/domain behavior (timelines, canvas, drawing, editor) | No — this *is* the app |

**Conclusion:** none of `server.py`'s routing is business logic — it's
transport. On iOS there is no cross-process boundary to bridge, so none of it
gets a Swift equivalent. What *does* migrate is: (a) the JSON schema itself
(so existing books stay readable), (b) the prompt-building logic in
`classes.py`, and (c) every behavior currently implemented in `app.js`'s
`methods`.

## 2. Target architecture

**Revised from the original proposal below**: storage is plain
`Codable` structs serialized as JSON — the same one-file-per-book shape as
`books/*.json` today — not SwiftData. See §3 for why.

```
┌─────────────────────────────────────────────────────────────┐
│                      Autorino.app (iOS)                      │
│                                                                │
│  SwiftUI Views  ──observe──▶  BookEditor (ObservableObject)   │
│  (one per tab,                 wraps a Codable Book struct:   │
│   replacing Vue                Chapter, Character, Location,  │
│   template blocks)              EventOrder, Event, Topic,     │
│       │                         Question, Comment, …          │
│       │ user actions                 │                        │
│       ▼                              ▼ debounced save          │
│  Domain services (plain Swift, no view dependency):           │
│   - PromptBuilder  (⟵ classes.py to_llm_prompt logic)         │
│   - LLMService     (⟵ llm_utils.py, protocol + GeminiLLMService)│
│   - BookStore      (Books/*.json in the app sandbox)          │
│   - DropboxSyncEngine (⟵ new: two-way sync of that same folder)│
│                                                                │
│  Persistence: plain JSON files in the app sandbox (Documents/  │
│  Books/), byte-compatible with the Mac's books/*.json — no     │
│  translation layer between "what's on disk" and "what syncs". │
└─────────────────────────────────────────────────────────────┘
        │ URLSession (direct)      │ URLSession (direct)
        ▼                          ▼
  Gemini REST API            Dropbox REST API
  (key in Keychain)          (OAuth PKCE, App
                               folder scope)
```

No local/on-device model backend — Gemini is the only `LLMService`.

No embedded HTTP server, no JSON-over-loopback, no `/api/*` routes. SwiftUI
views read a `Book` value straight out of a `BookEditor` (`@Published var
book: Book`, `Views/Shared/BookEditor.swift`) the way `app.js` currently
reads reactive `data()` state directly in its template — that part of the
shape *does* carry over conceptually (single reactive store, template-driven
views), just via a plain `ObservableObject` wrapping a `Codable` struct
instead of a Vue instance plus a save-to-disk round trip.

## 3. Data model mapping

**Storage engine, revised:** plain `Codable` structs written as JSON, one
file per book (`Books/<sanitized-title>.json`, sanitization ported
byte-for-byte from `server.py`'s `_save_book`), not SwiftData. This was
SwiftData in the original proposal below; it changed once Dropbox sync
became a requirement, because syncing means diffing/uploading/downloading
*files*, and SwiftData's object graph would need a serialize-to-JSON step
(plus its own change tracking reconciled against Dropbox's) bolted on
top — effectively rebuilding the same JSON layer SwiftData was meant to
replace, but as a second source of truth instead of the only one. Going
straight to `Codable` + JSON means the on-disk format the iOS app reads,
writes, and syncs *is* `books/*.json`, with no translation layer, matching
the Mac app's own approach.

`classes.py` is still the cleanest description of the domain (it's already
decoupled from transport). The Swift `Codable` structs in `ios/Autorino/Models/`
mirror it 1:1, with explicit snake_case `CodingKeys` — so the
camelCase/snake_case split from `app.js` collapses away on the Swift side
(there is only one representation, no serialize/deserialize boundary to
keep in sync), while the JSON *on disk* keeps its existing snake_case shape
for compatibility with any book the Mac app still writes.

| `classes.py` / JSON (`books/*.json`) | Swift `Codable` struct | Notes |
|---|---|---|
| `Book` | `Book` | Owns chapters, characters, locations, event orders, questions, topics, relations, canvas nodes, tags. No persisted `id` — identified by title/filename, same as today |
| `Chapter` | `Chapter` | `content` stays HTML on disk (unchanged), converted to/from `NSAttributedString` at the view layer only (see §5) |
| (chapter `comments`, app.js-only) | `Comment` | Quill range → `NSRange` offset+length into the chapter's plain text |
| (app.js `passages`, not in classes.py) | `Passage` | chapter reference + start/end anchor text, used as an LLM context scope |
| `Character` | `Character` | name, description, tags |
| `CharacterRelation` | `CharacterRelation` | character1/2 refs + relation type |
| (`canvas_nodes`, app.js-only) | `CanvasNode` | character ref + x/y — the relationship-map layout |
| `Location`, `LocationObject` | `Location`, `LocationObject` | shape/icon/area drawing primitives, unchanged |
| `EventOrder`, `Event` | `EventOrder`, `Event` | character columns + y-position timeline; `timeline_config` → `TimelineConfig` (clock/weekday/week/month/date/custom modes). Ships with a lenient custom decoder — real `timeline_config` objects only carry the keys relevant to their current mode, so a strict synthesized decoder would throw on real files |
| `Question` | `Question` | |
| `Topic` (+ notes/url_links) | `Topic`, `Note` | post-it notes with color |

`EventOrder.to_llm_prompt()` is `PromptBuilder.eventOrderPrompt(_:characters:)`
(`ios/Autorino/LLM/PromptBuilder.swift`) — same sort-by-`y_pos`-then-format-lines
logic, ported verbatim since it's pure text formatting, not I/O.
`generateMarkers`/`timeFromY` are similarly ported verbatim as `TimelineMath`
in `Models/EventOrder.swift`, ahead of the timeline view itself (§7).

## 4. Feature-by-feature migration map

| Vue/JS feature (`app.js` section) | iOS replacement | Status |
|---|---|---|
| Book list, create/rename/delete, autosave every 10s | `BookListView` + `BookStore`; `BookEditor` debounces saves ~1.5s after the last edit instead of polling every 10s | **Shipped** |
| `beforeunload` unsaved-changes guard | Not applicable — edits autosave via the debounce above; guard dropped rather than reproduced | **Shipped** (dropped) |
| Dropbox sync (net-new, not in the original Vue app) | `DropboxAuthService` (OAuth PKCE) + `DropboxSyncEngine` (two-way, cursor-based, conflict-preserving) | **Shipped** — see §6.5 |
| Characters tab (CRUD, tags, tag dropdown) | `CharactersListView` + `CharacterDetailView` | **Shipped** |
| Questions tab | `QuestionsListView` | **Shipped** (pulled forward — trivial enough not to defer) |
| Character canvas (draggable nodes, link mode, relation lines) | `CanvasView` using SwiftUI `Canvas` for link lines + `DragGesture` per node | **Shipped** — tap-to-place from a character pool stands in for the web version's drag-onto-map (no touch equivalent for native HTML drag-and-drop) |
| Locations tab (map + drawable objects: rect/ellipse/icons/areas) | `LocationsListView` + `LocationEditorView` + `LocationMapCanvas` (SwiftUI `Canvas`), `LocationTools`, `LocationIconRenderer` | **Shipped** — see §9 |
| Event orders (timeline, character columns, marker modes, gap sizing, drag to reposition) | `EventOrdersListView` + `TimelineView`/`TimelineConfigView`; `TimelineMath` (marker generation, `timeFromY`) | **Shipped** — LLM assistant side panel (today's per-feature pane) still deferred, to be wired onto `LLMAssistantSheet` rather than duplicated |
| Notes/Topics (post-its, colors, URL links) | `NotesListView` + `TopicDetailView` | **Shipped** — topic list pushes into a detail screen with the post-it grid and links section stacked, instead of app.js's three-pane `.notes-layout` |
| Text editor — chapters, rich text (Quill), comments, full-text mode | `ChapterEditorView` wrapping `UITextView` (`UIViewRepresentable`) bound to `NSAttributedString` | **Shipped** (layout/zoom/spell-language chrome deferred — see §5) |
| Word export (`docx.js`) / import (`mammoth.js`) | `DocxExporter`/`DocxImporter` + `ZipWriter`/`ZipReader`/`OOXMLDocumentParser` in `ios/Autorino/Word/` | **Shipped** — see §5 for the correction to this table's original import assumption |
| LLM: model picker, plausibility check, custom prompt, multi-turn chat, chat history, "include characters" / chapter-content-scope selector | `LLMService` protocol + `GeminiLLMService` (URLSession) | **Shipped** (Gemini only — no local/on-device model path; see §8) |
| i18n (`I18N` dict, `t(key)`) | Xcode String Catalog (`Localizable.xcstrings`), `String(localized:)` | Deferred — UI text is English-only for now |
| `/api/books*`, `/api/llm/*` routes; `server.py`, `start.sh`, `.env` parsing | **Deleted, not ported.** | N/A — pure transport for a browser that no longer exists |

## 5. Rich text editor (highest-risk item)

Today: Quill (HTML/Delta) for chapter bodies, `docx.js`/`mammoth.js` for
Word export/import, comments anchored to Quill ranges, a separate "full
text" concatenated-chapters mode, plus layout/zoom/spell-language UI chrome.

Proposed native approach:
- **Editing surface:** `UITextView` bridged via `UIViewRepresentable`,
  backed by `NSAttributedString`. Gives native bold/italic/underline/strike,
  fonts, sizes, lists, headings — the same formatting surface Quill exposes
  today — plus native selection, autocorrect, and `UITextChecker`-based
  spellcheck for free (replacing `teSpellLang`).
- **Storage format, shipped as:** chapter `content` stays **HTML on disk**,
  unchanged — not converted to RTF/AttributedString at rest. `HTMLConversion`
  (`Views/Editor/HTMLConversion.swift`) converts to/from `NSAttributedString`
  only at the view layer, on load and on a debounced save. This was a
  deliberate change from the original RTF proposal: keeping HTML on disk
  means a book edited on the iPhone still opens correctly in the Mac app
  (relevant now that Dropbox sync, §6.5, keeps both live at once — an RTF
  switch would have made that one-way).
- **Comments:** anchor by plain-text offset + length (`NSRange`) into the
  attributed string instead of a Quill `rangeIndex`/`rangeLength` pair —
  same concept, no framework dependency.
- **Full-text mode:** a computed view concatenating chapter titles + bodies,
  same as today's `fullTextQuill`, just built from the native attributed
  strings.
- **Word export/import — shipped, phase 10, in `ios/Autorino/Word/`.**
  Neither direction is a first-party API on iOS, which corrects an
  assumption this section originally made. Export took the path flagged
  as option 1 below (no new dependency); import turned out to need the
  same treatment, not the "likely free" API this section originally
  named — see the correction beneath the (still-accurate) option list:
  1. Port the existing hand-rolled paragraph/run walker in `app.js`
     (`exportChapterDocx`/`htmlToDocxParagraphs`) to build the same minimal
     OOXML by hand — no new dependency, more code to maintain. **Chosen.**
     `DocxExporter` walks an `NSAttributedString` (reusing
     `HTMLConversion`, the same parser already trusted for the editor)
     paragraph-by-paragraph, inferring heading level from font
     size+bold (calibrated against both `HTMLConversion`'s own `<h1-3>`
     output and `RichTextController.HeadingLevel`'s toolbar sizes, which
     use different point sizes for the same semantic level) and list/
     blockquote indent from paragraph style, and emits `<w:p>`/`<w:r>`
     OOXML. `ZipWriter` packages it — a from-scratch, stored-only
     (uncompressed) ZIP writer, valid per spec and sidesteps needing a
     compressor for output we control.
  2. Take a small, vetted dependency (e.g. a Swift docx/zip library) —
     less code, violates the "avoid unnecessary third-party dependencies"
     preference. **Not taken**, per the same call made for export.
  - **Correction to this section's original claim:** `.docx` import is
    **not** free. `NSAttributedString`'s `.docFormat`/`.officeOpenXML`
    document types (the ones that would read `.doc`/`.docx`) are
    AppKit-only — checked against the iOS SDK headers directly, iOS's
    `NSAttributedString.DocumentType` only has `.plainText`, `.rtf`,
    `.rtfd`, and `.html`. So `.docx` **import** needed the same
    "hand-roll it" treatment as export, not `mammoth.js`'s free lunch:
    `ZipReader` (reads a real, deflate-compressed `.docx`'s central
    directory — unlike `ZipWriter`'s own stored-only output, so it goes
    through Apple's first-party `Compression` framework rather than a
    hand-rolled inflate, since DEFLATE itself is a poor rebuild-by-hand
    candidate) extracts `word/document.xml`, and `OOXMLDocumentParser`
    (`XMLParser`, part of Foundation) walks `<w:p>`/`<w:r>` back into the
    same HTML shape the exporter reads from. This covers the same
    paragraph/run subset the exporter produces — not a general Word
    reader; tables, images, and footnotes aren't handled. Legacy `.doc`
    (pre-2007 binary format, not XML-in-a-zip) is out of scope entirely
    and rejected with a clear error rather than mishandled. Verified via
    a temporary in-app smoke test (export → `ZipReader` → parse → assert
    formatting survived) run in the Simulator, not just compiled —
    caught a real heading-level miscalibration before removal.

## 6. LLM integration

Today `llm_utils.py` picks Gemini vs. Ollama by string-matching the model
name, auto-launches a local `ollama serve` process, and streams chat history
through a server-side temp file. None of the process-management piece
(`start_ollama`) has an iOS analog — a sandboxed app cannot spawn `ollama
serve`.

Proposed:
- `protocol LLMService { func answer(prompt: String) async throws -> String;
  func chat(...) async throws -> String }`
- `GeminiLLMService`: direct `URLSession` calls to the Gemini REST API,
  same two call shapes as today (`answer_to_prompt`, multi-turn
  `chat_custom_prompt` with `system_instruction` built from selected
  characters). API key read from iOS **Keychain** (Settings screen),
  replacing `.env`/`GEMINI_API_KEY`.
- **No local/on-device model path.** Today's "local Ollama model" option is
  dropped, not replaced — no Ollama, no FoundationModels, no
  `OnDeviceLLMService`. Gemini is the only backend the iOS app ships. See §8.
- Chat history: shipped as per-book, persisted as JSON at `Application
  Support/ChatHistory/<sanitized-title>.json` (`ChatHistoryStore`) — matches
  today's default `persist:true` shared pane. Not stored inside the `Book`
  itself, so it doesn't round-trip through Dropbox sync or the Mac app; a
  feature pane wanting today's `persist:false` behavior (e.g. a future
  event-order assistant) just keeps its `[ChatMessage]` in view-local
  `@State` instead of using the store.
- Prompt/content-scope selection (chapters + passages, "include characters")
  is pure UI + `PromptBuilder` state — ports directly, no server involved
  even today beyond passing text through. Shipped as `ContentScopePickerView`,
  collapsed into an expandable section rather than the permanently-visible
  checklist app.js uses — see §6.5 for why phone width forced other chat-UI
  changes too.

### 6.5 LLM assistant UX (iPhone-specific change, not in the original)

app.js docks the LLM chat in a side panel next to the editor — reasonable on
desktop, unworkable on a ~390pt-wide phone. Shipped as `LLMAssistantSheet`: a
`.sheet` with `.presentationDetents([.medium, .large])` opened from a
toolbar button (`LLMAssistantButton`), starting at `.medium` so the editor
stays visible above it, draggable to `.large` for a focused conversation.
The content-scope picker (§6) collapses into the sheet instead of staying
permanently visible. `LLMAssistantButton`/`LLMAssistantSheet` are written
generically (take a `BookEditor` + a default scope) so the deferred tabs —
event orders in particular, which has its own LLM pane today — can reuse the
same surface once their views land, rather than growing a second chat
implementation.

Not yet done: presenting the same content as a `NavigationSplitView`
trailing column on iPad/regular-width instead of a sheet (today's fixed Vue
layout can't adapt to size class at all, which is the whole reason this was
worth doing — but this phase only shipped the phone-width sheet).

## 6.6 Dropbox sync (net-new — not in the original Vue app)

Books now sync between this Mac and an iPhone via Dropbox, because the app
moved from "single machine, single `books/` folder" to "two live copies
that both edit." Two independent halves:

- **Mac side: no code changes.** `books/` is relocated to (or symlinked
  into) `~/Dropbox/Apps/Autorino/`; the already-installed Dropbox desktop
  client syncs those plain JSON files the same way it syncs any other
  folder. `server.py` still just reads/writes `books/*.json` and has no
  idea Dropbox exists.
- **iOS side:** `DropboxAuthService` (OAuth 2.0 **PKCE** via
  `ASWebAuthenticationSession` — no client secret, appropriate for a public
  mobile client) + `DropboxClient` (thin `URLSession` wrapper over
  `files/list_folder`, `.../continue`, `files/upload`, `files/download` —
  no Dropbox SDK dependency) + `DropboxSyncEngine`, which:
  1. Pulls remote changes using a persisted `list_folder` cursor (cheap
     incremental syncs after the first).
  2. If a file changed on **both** sides since the last sync, never drops
     either: the remote version is saved alongside as
     `<title> (Dropbox <timestamp>).json` and flagged in Settings, while the
     local edit proceeds to overwrite Dropbox on the next push.
  3. Pushes locally dirty books (tracked per-file in `SyncIndexStore`,
     `Application Support/SyncIndex.json` — separate from the `Book` JSON
     itself, so it isn't something the Mac app or Dropbox ever sees).
- Dropbox App folder scope was chosen over full Dropbox access for the
  narrower OAuth consent screen and least-privilege default; see
  `ios/README-iOS.md` for the exact Dropbox App Console setup steps.

## 7. Phased plan

Each phase ships something independently testable, per the migration rules.
Phase 1 is complete; phases are renumbered from the original proposal to put
Dropbox sync first, since it was pulled forward from "stretch" to
"required" this session.

1. ~~**Data core + Dropbox sync**~~ — Codable models (§3), `BookStore`,
   Dropbox OAuth + two-way sync (§6.6). **Done.**
2. ~~**Book management**~~ — list/create/rename/delete, debounced autosave,
   Settings (Dropbox + Gemini key). **Done.**
3. ~~**Characters**~~ — list/CRUD/tags. **Done.**
4. ~~**Questions**~~ — pulled forward from its original later slot; trivial
   enough not to defer. **Done.**
5. ~~**Chapter text editor + LLM (Gemini path)**~~ — rich text via
   `UITextView`, comments, passages, full-text mode, `LLMAssistantSheet`.
   **Done.**
6. ~~**Event orders**~~ — `EventOrdersListView`/`TimelineView`/
   `TimelineConfigView`; `TimelineMath` (marker generation, `timeFromY`)
   ported and unit-testable. **Done** — moved ahead of Canvas/Locations
   since it landed first; its own LLM assistant panel is still open, see
   the feature table above.
7. ~~**Character relationship canvas**~~ — `CanvasView`: tap-to-place nodes,
   drag to reposition, link mode + relation modal, relation lines via
   SwiftUI `Canvas`. **Done.**
8. ~~**Locations**~~ — list + map editor (shapes/icons/areas). **Done** — see §9.
9. ~~**Notes/Topics**~~ — post-its, URL links. **Done** — see §10.
10. ~~**Word import/export**~~ — `DocxExporter`/`DocxImporter`,
    `ZipWriter`/`ZipReader`, `OOXMLDocumentParser` (§5). **Done** — both
    directions needed a hand-rolled OOXML implementation, correcting this
    doc's original assumption that import was free via `NSAttributedString`.
11. **Localization** — String Catalog (en/de), matching current coverage.
12. **Polish** — `NavigationSplitView` trailing-column presentation for
    `LLMAssistantSheet` on iPad/regular width (§6.5); layout/zoom/spell-
    language editor chrome; event-order LLM assistant panel wired onto
    `LLMAssistantSheet`.

**No on-device/local LLM phase.** Dropped as a non-goal, not deferred — see §8.

## 8. Assumptions & open decisions

- **Dropbox, not iCloud/CloudKit, is the sync mechanism**, and it's shipped
  this phase rather than deferred as a stretch goal — the original proposal
  assumed no shared filesystem with the Mac app at all; see §6.6 for the
  actual mechanism (Dropbox App folder + a relocated/symlinked `books/`).
- **Plain JSON files, not SwiftData, are the storage engine** (§3) — chosen
  specifically because it makes Dropbox sync a file diff instead of a
  translation layer. JSON stays the *only* representation, not an
  interchange format bolted onto a database.
- **No local/on-device model at all — confirmed non-goal, not a deferred
  phase.** Today's Ollama option is dropped outright; it is *not* replaced
  by Apple FoundationModels or anything else. Gemini (`GeminiLLMService`) is
  the only `LLMService` the iOS app ships or will ship. If on-LAN access to
  a Mac running Ollama is wanted later, that would be a new decision to
  revisit explicitly, not an implied continuation of this plan.
- **Gemini API key lives in Keychain**, entered in a Settings screen,
  replacing `.env` parsing.
- **`.docx` export and import approach (§5) — resolved, phase 10:** the
  manual-OOXML-writer path was chosen for export over a dependency; import
  turned out to need the same manual treatment (a hand-rolled ZIP reader
  + `XMLParser` walk), not the free `NSAttributedString` path this
  section originally assumed — see §5's correction.
- **No FastAPI/HTTP layer of any kind ships in the iOS app** — confirmed
  non-goal per the migration rules; all `server.py` routes are transport,
  not logic, and are deleted rather than translated.

## 9. Locations (phase 8)

Ported as `LocationsListView` → `LocationEditorView` → `LocationMapCanvas`,
plus two pure-logic files that follow the `TimelineMath` precedent of keeping
geometry out of the view: `Models/LocationTools.swift` (the `AREA_DEFAULTS`/
`ICON_DEFAULTS` tables, `niceInterval`, canvas sizing, ruler ticks) and
`Views/Locations/LocationIconRenderer.swift` (the ten icons, ported from
app.js's inline SVG `<g>` blocks).

The whole map draws in a **single `Canvas` pass** rather than one view per
object — app.js gets per-child `@mousedown` handlers for free from SVG, but
a map with hundreds of objects shouldn't mean hundreds of SwiftUI views, so
hit-testing is done manually in `LocationMapCanvas.hitTest`, topmost-first.
Areas hit-test against their actual path (a lake's bounding box can cover
half the map); roads, being open strokes, test distance-to-segment.

### Touch adaptations (departures from app.js)

- **Closing an area** is an explicit **Finish** button, not app.js's
  double-click / tap-near-the-first-point (app.js:1364-1371) — both are too
  imprecise under a fingertip to be the only way to close a polygon. An
  **Undo** button removes the last point.
- **Moving an object** requires a long press first (~0.28s) before the drag
  takes over. This is the one thing that has to give: the map lives in a
  `ScrollView`, and a plain drag has to stay available for panning. Shape
  tools, which are unambiguously rubber-banding, still take the drag
  immediately. Gestures are attached **conditionally per tool** rather than
  always-on with a `GestureMask` — on a leaf view there are no subviews to
  defer to, so a masked-off gesture still blocks the enclosing `ScrollView`.
- **The properties panel** is a sheet, not a pane floating over the canvas
  (app.js:2397-2413), which at phone width would cover most of the map.
- **Tool icons are SF Symbols, not emoji.** Several of app.js's emoji
  (🌳🏠🏰…) have no font coverage on iOS and render as `?` boxes.

### Two compatibility fixes this phase forced

- **`CSSColor`** (`Models/CSSColor.swift`) parses and re-emits the CSS color
  strings in `books/*.json`. Area fills are `rgba(...)` (translucent) while
  shapes/icons are `#rrggbb`; parsing an `rgba` fill and writing back hex
  would silently flatten a see-through lake to opaque **in the Mac app**
  after Dropbox sync. Alpha is kept in the model and the original form is
  re-serialized.
- **`Comment.rangeIndex`/`rangeLength` are now optional.** app.js's
  `addComment` leaves them `null` when there was no live selection
  (app.js:1665-1676), and older books omit the keys entirely. Requiring them
  made the *entire* `Book` decode throw, and because `BookStore.reload()`
  skips books that fail to decode (`try?`), the book **silently vanished
  from the library** — all three real books in `books/` were affected, not
  just one. app.js already guards on `rangeIndex == null` (app.js:1680);
  the Swift side now mirrors that and re-encodes `nil` back to `null`.
  Worth noting as a class of bug: a strict `Codable` shape against
  another app's JSON turns one unexpected field into an invisible book.

## 10. Notes/Topics (phase 9)

Ported as `NotesListView` (topics list, create/delete) → `TopicDetailView`
(the post-it grid + links section for the selected topic). app.js's
`.notes-layout` is three side-by-side panes — topics sidebar, post-it grid,
URL sidebar (app.js:2579-2633) — which doesn't fit phone width; the iOS
version follows the same pattern as Locations/Canvas: the topics list is its
own screen, and picking one pushes into `TopicDetailView`, where the post-it
grid and links live in two stacked `List` sections instead of two side
panes.

- **Post-it color picker** is a `Menu` listing `NotePostItColor.all`, a
  direct port of app.js's `POST_IT_COLORS` (app.js:24-29) — same eight
  values and labels, rendered via `CSSColor.color(_:fallback:)` (already
  used by Locations, see §9) rather than a new hex parser.
- **Notes and URL links are both `List` rows** with swipe-to-delete
  (`.onDelete`) instead of app.js's per-item ✕ button, matching the
  swipe-to-delete convention already used for topics, locations, and
  characters elsewhere in the app.
- **Verification note:** driving this feature end-to-end in the iOS
  Simulator via XCUITest surfaced a harness quirk worth recording — a
  `List` that flips between an empty-state view and populated rows inside
  the same live session doesn't reliably reappear in XCUITest's
  accessibility snapshot (confirmed as a test-harness artifact, not an app
  bug: screenshots and the saved book JSON on disk were correct at every
  step). Relaunching the app before each such assertion forces a fresh
  `BookStore.reload()` and sidesteps it. Two SwiftUI accessibility-typing
  quirks also came up and are worth knowing for future UI tests in this
  app: a `Link` surfaces to XCUITest as a `Button` (not `StaticText`), and
  a multiline `TextField(axis: .vertical)` exposes its content as a
  `value`, not a `label`.
