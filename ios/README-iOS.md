# Autorino for iOS

Native SwiftUI port of the Vue/Python app in the repo root. See
`docs/migration-architecture.md` for the full architecture writeup. This
file is the practical "how do I build and set this up" doc.

## Status

**Shipped and building (phases 1–10):**
- Project scaffold, all data models (full parity with `books/*.json`)
- Local persistence (`Books/*.json` in the app sandbox — same schema/
  filenames as the Mac app)
- Dropbox sync (OAuth PKCE, two-way sync, conflict handling)
- Book list (create/rename/delete), Settings (Dropbox + Gemini key)
- Characters (list/CRUD/tags)
- Questions (bonus — trivial enough to do in full this pass)
- Chapter editor (rich text via `UITextView`, comments, passages, full-text
  mode) + the LLM assistant, redesigned as a bottom sheet for phone width
- Event orders: `EventOrdersListView`/`TimelineView`/`TimelineConfigView`,
  built on the `TimelineMath` marker math — only its own LLM assistant side
  panel is still open (reuse `LLMAssistantSheet` rather than duplicate it)
- Canvas (relationship map): `CanvasView` — tap-to-place characters
  (touch stand-in for the web version's drag-onto-map), drag to reposition,
  link mode + relation modal, relation lines drawn with SwiftUI `Canvas`
- Locations (map editor): `LocationsListView` + `LocationEditorView` +
  `LocationMapCanvas` — shapes/icons/areas drawn in one `Canvas` pass;
  closing an area is an explicit Finish button (touch stand-in for the web
  version's double-click-to-close); moving an object requires a long press
  first so a plain drag still pans the map. See
  `docs/migration-architecture.md` §9 for the full writeup, including two
  book-compatibility fixes this phase forced (`CSSColor`, optional
  `Comment.rangeIndex`/`rangeLength` — the latter was silently hiding every
  real book in `books/` from the library before this phase caught it).
- Notes/Topics: `NotesListView` + `TopicDetailView` — topics list pushes
  into a detail screen with the post-it grid and URL links stacked, in
  place of app.js's three-pane `.notes-layout`. Post-it color picker is a
  direct port of `POST_IT_COLORS`. See `docs/migration-architecture.md`
  §10, including two XCUITest accessibility-typing quirks worth knowing
  before writing more UI tests against this app (`Link` surfaces as a
  `Button`; a multiline `TextField(axis: .vertical)` exposes text as
  `.value`, not `.label`).

- Word import/export: `DocxExporter`/`DocxImporter` in `Autorino/Word/` —
  export builds minimal OOXML by hand (`ZipWriter` + a paragraph/run
  walker over `NSAttributedString`, ported from app.js's
  `htmlToDocxParagraphs`/`nodeToRuns`); import needed the same treatment,
  not a free ride: iOS's `NSAttributedString` has no `.docx`/`.doc`
  document type at all (that's AppKit-only), so `ZipReader` (deflate via
  the first-party `Compression` framework) + `OOXMLDocumentParser`
  (`XMLParser`) rebuild HTML from `word/document.xml`. Covers the same
  paragraph/run subset the exporter produces — bold/italic/underline/
  strike, `<h1-3>`, blockquote indent — not tables/images/footnotes, and
  not legacy binary `.doc` (rejected with a clear error). Reachable from
  the chapter list toolbar (Import File / Export DOCX) and per-chapter
  (swipe action, or the editor's `···` menu).

**No local/on-device LLM — confirmed non-goal, not deferred.** The iOS app
ships Gemini only (`GeminiLLMService`). Today's Ollama option is dropped
outright and is not replaced by FoundationModels or anything else.

**Deferred to later phases** (models exist, views are placeholders):
localization (String Catalog).

## Build

```bash
cd ios
xcodegen generate        # regenerate Autorino.xcodeproj from project.yml after any file add/remove
open Autorino.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Autorino.xcodeproj -scheme Autorino \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

`project.yml` is the source of truth for project structure — **add new
Swift files by creating them under `Autorino/`, then re-run `xcodegen
generate`**; don't hand-edit the generated `.xcodeproj`.

## One-time setup

### 1. Gemini API key

Settings → Gemini → paste a key from https://aistudio.google.com/apikey.
Stored in the Keychain, same role as today's `.env`/`GEMINI_API_KEY`.

### 2. Dropbox sync

1. Go to https://www.dropbox.com/developers/apps → **Create app**.
2. Choose **Scoped access** → **App folder** access → name it (e.g.
   "Autorino") → Create.
3. On the app's **Settings** tab, copy the **App key**.
4. On the same Dropbox app's **Settings** tab, under **OAuth 2** →
   **Redirect URIs**, add `db-autorino://oauth2redirect` — this scheme is
   fixed (see `ios/project.yml`'s `CFBundleURLTypes`) and does not depend
   on your app key, so this step never needs to be repeated even if you
   rotate the key later.
5. Under **Permissions**, the App folder scope already grants
   `files.metadata.read/write` and `files.content.read/write` — just hit
   **Submit** if it asks you to save.
6. Build and run the app, then Settings → **Dropbox Sync**, paste the App
   Key into the field there and tap **Save key**. It's stored in the
   Keychain only — never hardcoded in source, never leaves the device
   except as the OAuth `client_id` (Dropbox app keys are public client
   identifiers, not secrets, the same way an OAuth client ID is).
7. On the Mac, point `books/` at Dropbox so the already-installed Dropbox
   desktop client syncs the same files the app folder scope confines the
   iOS app to:
   ```bash
   # from the repo root, with the Mac app not running
   mkdir -p ~/Dropbox/Apps/Autorino
   mv books/* ~/Dropbox/Apps/Autorino/ 2>/dev/null  # move any existing books over
   rmdir books
   ln -s ~/Dropbox/Apps/Autorino books
   ```
   `server.py` needs no code changes — it just reads/writes `books/`,
   which is now a symlink into the Dropbox folder Dropbox itself keeps in
   sync.
8. Back in Settings, tap **Connect Dropbox** and sign in. Books sync
   automatically on launch, on pull-to-refresh in the book list, and via
   **Sync now** in Settings.

### Conflict handling

If a book changed on both the Mac and the phone between syncs, the phone's
edit wins the shared filename and the Dropbox version is saved alongside
as `<title> (Dropbox <timestamp>).json` — nothing is silently dropped.
Settings lists any such conflicts; merge by hand and delete the extra copy
once you're done.

## Notes for whoever picks up the next phase (Localization)

- `BookTabContainer` (`Views/Shared/BookTabContainer.swift`) is where the
  placeholder tabs live — swap `PlaceholderTabView` for a real view per
  tab as each one lands. All tabs are now real views, including Word
  import/export (phase 10); localization is next, see
  `docs/migration-architecture.md` §7.
- If a future `.docx` import needs more than paragraphs/runs (tables,
  images, styles beyond bold/italic/underline/strike/headings/
  blockquote), `OOXMLDocumentParser` is the place to extend — it's a
  straightforward `XMLParser` delegate over `word/document.xml`, not a
  black box. `ZipReader`/`ZipWriter`/`Inflate` in the same directory are
  general enough to reuse for anything else that needs a `.docx`-shaped
  container.
- Tab content views (`CanvasView`, `TimelineView`, etc.) cannot rely on
  `.toolbar`/`.navigationTitle` bubbling up to the shared nav bar — the
  single `NavigationStack` lives above `BookTabContainer`'s `TabView`, and
  only `BookTabContainer`'s own `.toolbar` merges into it. Put per-tab
  controls (add/link/zoom buttons, a title) in the view body instead, the
  way `CanvasView`'s `header` and `TimelineView`'s `toolbar` computed
  property do — confirmed by XCUITest: a `.toolbar` item declared on
  `CanvasView` itself never appeared in the accessibility tree.
- `LLMAssistantSheet`/`LLMAssistantButton` are written to be reusable from
  any tab, not just the editor — wire them into the event-order assistant
  the same way once that gets picked up.
- The bundle id (`com.autorino.app`) in `project.yml` is a placeholder;
  change it (and re-provision) before shipping to a device you don't
  control via Xcode's free personal team. The Dropbox redirect scheme
  (`db-autorino`) is independent of the bundle id and doesn't need to
  change with it.
