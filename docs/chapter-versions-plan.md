# Chapter versions — implementation plan (web + iOS)

Status (2026-10-05): **implemented on both apps, uncommitted.** Web verified end-to-end in a
browser; iOS verified end-to-end in the Simulator (German UI, temporary XCUITest target, fresh
device without Dropbox; scaffolding removed again). Ship both apps together (see §1.4).

iOS walkthrough covered: new version from main (named) and from an empty page, banner with word
count, editing a version, switching keeps edits, Make main (text, comments and name swap), comments
follow their text, passages sheet in alternative mode, rename, Compare (2 scope items + prefilled
prompt), delete (→ `before content removed` snapshot in `Documents/Backups`), chapter row
"2 Versionen", total counts main only. Chapters without versions gain no keys in the saved JSON.

### Remaining
1. Cross-app round-trip through Dropbox (web ⇄ iPhone) with a book holding versions.

### Deviations from the plan below
- Web: also fixed a pre-existing bug found while testing — the Quill instances were stored in Vue
  `data` without `markRaw`, so Quill never parsed the loaded chapter HTML into its model
  (`getText()` empty → LLM context / passage verify of the open chapter saw no text, placeholder
  drawn over the text). Now `Vue.markRaw(new Quill(...))`.
- iOS: `LLMAssistantHost` re-creates the assistant (`.id(seedKey)`) when its default scope or
  prefilled prompt changes; chat history is unaffected (per-book store).

## 0. Feature summary

- A chapter can have alternative versions besides its main text.
- **V1 = main version.** It is the chapter's existing `content`/`comments`. Only V1 counts toward
  word totals, full text, DOCX book export, digests, passages and default LLM context.
- **New version**: next number = highest existing number + 1 (numbers are not reused while a higher
  one exists). Source: a copy of any existing version (default V1) or an empty page. Optional
  short name.
- **Direct editing** of any version in the chapter editor, with a clear "Editing V2 · not counted"
  indicator and that version's own word count.
- **Make main (swap)**: exchanges text, comments and name between V1 and Vn. Numbers are slots, so
  after swapping V1⇄V3 the old main text is now V3. Lossless and reversible (swap back).
- **Rename / delete** a version (delete asks for confirmation; V1 can't be deleted).
- **LLM comparison**: versions can be added to the LLM context, plus a one-click "Compare with
  main" action.

## 1. Data format (the contract — do this first, on both sides)

### 1.1 Schema

```jsonc
// chapter in books/<title>.json
{
  "id": "…", "label": "…", "name": "…",
  "content": "<html>",            // V1 = main, unchanged meaning
  "comments": [ … ],              // V1's comments, unchanged
  "version_name": "lighter tone", // NEW, optional: V1's version name
  "versions": [                   // NEW, optional: alternatives, sorted by number
    { "id": "…", "number": 2, "name": "darker ending",
      "content": "<html>", "comments": [ … ],   // same comment shape as chapter comments
      "created_at": "2026-10-05T12:00:00Z" }     // ISO 8601
  ]
}
```

- Both keys are **omitted when empty** (`versions` absent if no alternatives, `version_name`
  absent if empty), so books without versions stay byte-identical on both sides.
- Missing keys decode as `[]` / `""`.

### 1.2 Web (`app.js`)

- `serializeBook` (app.js:117ff): extend the chapter mapper with `version_name` and `versions`
  (each version's comments go through the same comment mapper; factor that into a small
  `serializeComments` function used by both).
- `deserializeBook` (app.js:163) passes `data.chapters` through unchanged, so versions already
  survive loading. Just normalize `versions ||= []` and `version_name ||= ''` there so the
  template can rely on them.
- `addChapter` / full-text rebuild (app.js:1847, 2085): new chapters get `versions: []`.
  The full-text rebuild reuses the existing chapter objects, so versions are kept.

### 1.3 iOS (`ios/Autorino/Models/Chapter.swift`)

- Add `var versionName: String` and `var versions: [ChapterVersion]`.
- `Chapter` currently uses compiler-generated Codable → write a hand-written `init(from:)` with
  `decodeIfPresent` + defaults for **every** field (CLAUDE.md lenient-decode rule), plus
  `encode(to:)` that skips `version_name`/`versions` when empty.
- New `struct ChapterVersion: Codable, Identifiable, Hashable { id, number, name, content,
  comments: [Comment], createdAt }` with snake_case `CodingKeys` (`created_at`), also decoded
  leniently. Put it in a new file `Models/ChapterVersion.swift` → **`xcodegen generate`**.
- `classes.py`: no change (versions don't reach server-built prompts).

### 1.4 Rollout risk: old builds drop versions

An app build without this feature drops `versions` when it saves a chapter's book (web:
`serializeBook` lists chapter fields explicitly; iOS: unknown keys are lost on re-encode).
Mitigation:
- Ship both apps together; rebuild the phone app before creating the first version.
- If it happens anyway, nothing is gone for good: the Dropbox pull and the save path snapshot
  before overwriting.

### 1.5 Shrink check (`backups.py:book_shrank`, `BackupStore.bookShrank`)

Change both, identically:
- Also return true when the **total number of versions across all chapters** drops (this makes
  "delete version" always snapshot before the save, with no client-side force needed).
- Measure text length as main + all version contents. A swap then doesn't count as shrinking
  (nothing is lost), but deleting a long version does.

## 2. Shared behaviour (implement identically on both sides)

Pure helpers that operate on a chapter:

| Operation | Behaviour |
|---|---|
| `nextVersionNumber(ch)` | `max(1, …versions.number) + 1` |
| `createVersion(ch, sourceVersionId \| 'main' \| null, name)` | `null` = empty page; otherwise copies that slot's `content`. Comments are **not** copied (their anchors belong to the source text). Appends `{id: uid, number, name, content, comments: [], created_at: now}`. Returns the new id. |
| `swapWithMain(ch, versionId)` | Exchanges `content`, `comments` and name (`version_name` ⇄ `version.name`) between the chapter and that version. `number`, `id` and `created_at` stay in place. |
| `renameVersion(ch, versionId \| 'main', name)` | Sets `version.name` / `version_name`. |
| `deleteVersion(ch, versionId)` | Removes it (confirm in UI first). |
| slot accessor | "the slot being edited" = the chapter itself (main) or the version object; both carry `content` + `comments`, so the editor, comments and word count bind to the slot. |

Things that intentionally stay **main-only**: book/chapter word counts in lists and totals,
full-text view, DOCX book export, digests (iOS `DigestService` hashes `chapter.content`, so a swap
makes the digest show as stale — acceptable), passages (anchor in main text; a swap can make
a passage stop resolving — acceptable, as passages already fail gracefully).

Passages while an alternative is open: disable "add passage" (web passage panel, iOS
`PassagesSheet`) with a hint "Passages refer to the main version".

Per-chapter DOCX export: exports the slot that is open (filename suffix ` (V2)` for alternatives).

## 3. Web UI (`app.js`)

State: `currentVersionId: null` (null = main). Reset to null in `selectChapter` and on book
load/switch.

- **Editor binding**: replace the `this.book.chapters.find(c => c.id === chId).content` reads/
  writes in `initQuill`, `selectChapter`, `saveCurrentChapterContent` with the slot accessor
  `editorSlot(chId, versionId)`. Capture `versionId` alongside `chId` in `initQuill` (as
  `_quillVersionId`) exactly like `_quillChapterId`, so a late `text-change` can never write into
  the wrong slot.
- `selectVersion(id)`: `saveCurrentChapterContent()` → set `currentVersionId` → tear down and
  `initQuill()` again (same pattern as `selectChapter`). Undo history resets automatically.
- **Version bar** in `.te-editor-header` (template ~line 3160): pills `V1 · main`, `V2 darker
  ending`, …, `＋`. Only the `＋` pill shows while no alternatives exist.
  - `＋` opens a small inline form: source `<select>` (V1 default, every other version, "Empty
    page"), name input, Create → creates and selects the new version.
  - When an alternative is active: badge `Editing V2 · 1 234 words · not counted`, buttons
    `⇄ Make main`, `🔍 Compare with main`, `✎ Rename`, `✕ Delete` (with `confirm()`).
  - `Make main`: save → swap → `currentVersionId = null` → re-init Quill (the user now sees the
    promoted text as V1) → `mark()` → toast "V3 is now the main version".
- **Comments**: `addChapterComment` (2122), `removeComment` (2176) and the comments list
  (3245ff) use the slot's `comments` instead of `currentChapter().comments`.
- **Sidebar card** (3143): append `· 3 versions` when `versions.length`. Word count stays main.
- `exportChapterDocx` from the header exports the open slot.

## 4. iOS UI

- `Models/ChapterVersion.swift`: struct + `extension Chapter` with the §2 helpers as `mutating`
  functions and `func content(slot: String?) -> String`, `mutating func setContent(_:slot:)`,
  same for comments (`slot == nil` = main).
- `ChapterEditorView`:
  - `@State private var versionId: String?` (nil = main).
  - `loadContent()`, `commit(_:)`, `commentsBinding`, `exportDocx()` go through the slot accessors.
  - Switching versions: `save()` (flush both debounces) → set `versionId` → `loadContent()`.
    Verify that `RichTextView`'s undo stack does not reach back into the other version's text; if it
    does, clear it on reload.
  - The `ellipsis.circle` menu gets a **Versions** submenu: one row per version (checkmark on
    the open one), `New version…`, and, when an alternative is open, `Make main version`,
    `Compare with main`, `Rename…`, `Delete version` (`.confirmationDialog`).
  - When an alternative is open, a slim banner between `FormatToolbar` and the page:
    `Version 2 · darker ending · 1,234 words · not counted` + `Make main` button. (Body content,
    not `.toolbar`, so it renders reliably — see the CLAUDE.md gotcha.)
  - `navigationTitle` gets the suffix ` · V2` when an alternative is open.
- `NewVersionSheet` (Form): `Picker` "Start from" (V1, each version, Empty page; default V1),
  `TextField` "Name (optional)", Create.
- `ChapterListView.ChapterRow`: append `· 3 versions`. `Chapter.wordCount` stays main-only.
- `PassagesSheet`: disabled-add state when opened from an alternative (pass `versionId`).

## 5. LLM: comparing versions

### Scope item

- Web: new content-selector item type `'version'` `{type: 'version', id: versionId, chapterId}`.
  `llmContentSuggestions` / `eoLlmContentSuggestions` list each version after its chapter, as
  `Ch 3 – Title · V2 (darker ending)`; the plain chapter item is labelled `… · V1` only when that
  chapter has versions. `runLlmPrompt` (and the EO equivalent) render it as
  `--- Ch 3 – Title · V2 (darker ending) ---\n<plain text>`.
- iOS: `ContentScopeItem.Kind.version` (id = version id; look up across chapters).
  `PromptBuilder.contentContextText` handles it; add `versionDisplayName`. In
  `ContentScopePickerView.chapterRow`, show versions as indented sub-rows (reuse
  `scopeRow(… leadingPad: true)`).

### Default context while an alternative is open

When no explicit scope is chosen, the "current chapter" text sent to the model is **the open
slot**, labelled with its version (web: the `else` branch in `runLlmPrompt` ~997; iOS:
`ChapterEditorView`'s `defaultScope` becomes `[.version(id)]` when an alternative is open).

### "Compare with main" action

Opens the LLM assistant (web: the LLM pane in custom/chat mode; iOS: `showingLLM = true`) with
scope = [chapter (V1), that version] and a prefilled, editable prompt, e.g.
"Compare version 1 and version 2 of this chapter: differences in plot, tone, pacing and
characterization; strengths and weaknesses of each." The user sends it; nothing is sent
automatically.

## 6. Localization

New strings through `t()` + `I18N.de` (web) and `Localizable.xcstrings` (iOS, add by hand and
verify via the built `de.lproj`). Remember `String(localized:)` for ternaries/custom view
params. Strings: Versions, New version, Start from, Empty page, Name (optional), Make main
version, Compare with main, Rename, Delete version, "Delete version %@?", not counted,
"%lld versions", main, "V%lld is now the main version", "Passages refer to the main version",
the compare prompt.

## 7. Implementation order

1. Schema + lenient decode/encode on both sides + shrink checks (§1). Verify by round-trip:
   a book with versions written by web → opens on iOS with versions intact → iOS edit → web
   still sees them; a book without versions stays byte-identical after an iOS save.
2. Web helpers + UI (§2, §3).
3. iOS helpers + UI (§2, §4); `xcodegen generate`; `xcodebuild … build`.
4. LLM scope + compare action, both sides (§5).
5. Localization (§6).
6. Verify end-to-end (`run` skill): create V2 from V1, V3 empty, edit each, totals unchanged,
   swap V1⇄V3 and back, comments travel with text, delete V2 → a snapshot exists in backups,
   Dropbox sync round-trip web ⇄ iPhone, compare prompt contains both texts.

No sync-engine changes: `dropbox_sync.py` / `FolderSyncEngine.swift` treat books as opaque
files, and conflicts keep both books, versions included.
