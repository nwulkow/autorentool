"""Conflict copies of books: finding them and resolving them.

Sync never overwrites a book that changed on both sides; it keeps the other
side as a separate file (dropbox_sync._write_conflict_copy):

    <base> - Dropbox conflict <stamp>.json   remote side of a both-sides edit
    <base> - local conflict <stamp>.json     local side on a device's first sync
    <base> (Dropbox <stamp>).json            older copies, title left unchanged

A file is a conflict copy only while <base>.json exists and is readable;
otherwise it may be the only usable copy of that book and stays an ordinary
book in the list. Detection is by filename
so a copy whose title still equals the main book's can't be mistaken for it.
The same rules live in ios/Autorino/Persistence/BookConflicts.swift.

Every resolution keeps a recoverable copy (CLAUDE.md, "Never lose a book"):
the main book is snapshotted before it is changed, and a copy that is set
aside is snapshotted before its file is removed (and moved to the Dropbox
Trash by the caller via mark_deleted). A failed snapshot aborts.
"""

import json
import os
import re

import backups

_PATTERNS = (
    re.compile(r"^(?P<base>.+) - (?P<label>Dropbox conflict|local conflict) "
               r"(?P<stamp>\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})(?: \d+)?\.json$"),
    re.compile(r"^(?P<base>.+) \((?P<label>Dropbox) (?P<stamp>[^)]*)\)\.json$"),
)


def looks_like_copy(filename):
    """Whether the name has a conflict copy's shape, whatever exists."""
    return any(rx.match(filename) for rx in _PATTERNS)


def classify(filename, existing):
    """{base_file, label, stamp} when `filename` is a conflict copy of a book
    in `existing` (a set of filenames), else None. A copy of a copy is
    attributed to the main book at the root of the chain."""
    for rx in _PATTERNS:
        m = rx.match(filename)
        if not m:
            continue
        base_file = m["base"] + ".json"
        if base_file == filename:
            continue
        # Walk up even when the middle copy is gone (already resolved).
        parent = classify(base_file, existing)
        if parent:
            base_file = parent["base_file"]
        elif base_file not in existing:
            continue
        return {"base_file": base_file, "label": m["label"], "stamp": m["stamp"]}
    return None


def _book_files(books_dir):
    try:
        return {n for n in os.listdir(books_dir) if n.endswith(".json")}
    except FileNotFoundError:
        return set()


def _copies(books_dir):
    """[(filename, info, main_book)] for every conflict copy whose main book
    is readable."""
    existing = _book_files(books_dir)
    out, mains = [], {}
    for name in sorted(existing):
        info = classify(name, existing)
        if not info:
            continue
        if info["base_file"] not in mains:
            main, ok = backups.load_json(os.path.join(books_dir, info["base_file"]))
            mains[info["base_file"]] = main if ok and isinstance(main, dict) else None
        if mains[info["base_file"]] is not None:
            out.append((name, info, mains[info["base_file"]]))
    return out


def conflict_files(books_dir):
    """Filenames of every conflict copy in `books_dir`."""
    return {name for name, _, _ in _copies(books_dir)}


def list_conflicts(books_dir):
    """Every conflict copy with its parsed book (None when unreadable) and
    the title of the main book it belongs to."""
    out = []
    for name, info, main in _copies(books_dir):
        book, ok = backups.load_json(os.path.join(books_dir, name))
        out.append({
            "file": name,
            **info,
            "base_title": main.get("title"),
            "book": book if ok and isinstance(book, dict) else None,
        })
    return out


def _check_copy(books_dir, filename):
    info = next((i for name, i, _ in _copies(books_dir) if name == filename), None)
    if not info:
        raise ValueError("Not a conflict copy.")
    return info


def _load_book(path):
    book, ok = backups.load_json(path)
    if not ok or not isinstance(book, dict):
        raise ValueError(f"{os.path.basename(path)} is not a readable book; nothing was changed.")
    return book


def _write(path, book):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(book, fh, indent=4, ensure_ascii=False)
    os.replace(tmp, path)


def set_aside(books_dir, filename):
    """Removes a conflict copy after snapshotting it. Restorable from
    Settings → Backups."""
    _check_copy(books_dir, filename)
    path = os.path.join(books_dir, filename)
    backups.snapshot(path, "books", "conflict set aside")
    os.remove(path)


def adopt(books_dir, filename):
    """Makes the copy's version the main book (keeping the main title), then
    sets the copy aside. Returns the main book's filename."""
    info = _check_copy(books_dir, filename)
    main_path = os.path.join(books_dir, info["base_file"])
    main = _load_book(main_path)
    copy = _load_book(os.path.join(books_dir, filename))
    copy["title"] = main.get("title")
    backups.snapshot(main_path, "books", "before conflict resolved")
    _write(main_path, copy)
    set_aside(books_dir, filename)
    return info["base_file"]


def take_chapters(books_dir, filename, chapter_ids):
    """Copies the given chapters from the conflict copy into the main book:
    a chapter the main book has is replaced (keeping any alternative
    versions only the main book has), a chapter it lacks is inserted after
    the nearest chapter that precedes it in the copy. Returns the main
    book's filename."""
    info = _check_copy(books_dir, filename)
    main_path = os.path.join(books_dir, info["base_file"])
    main = _load_book(main_path)
    copy = _load_book(os.path.join(books_dir, filename))
    wanted = set(chapter_ids or [])
    copy_chapters = copy.get("chapters") or []
    chapters = list(main.get("chapters") or [])
    if not wanted.intersection(c.get("id") for c in copy_chapters):
        raise ValueError("None of those chapters is in this version.")

    backups.snapshot(main_path, "books", "before conflict merge")
    for i, ch in enumerate(copy_chapters):
        if ch.get("id") not in wanted:
            continue
        taken = json.loads(json.dumps(ch))
        idx = next((j for j, c in enumerate(chapters) if c.get("id") == ch.get("id")), None)
        if idx is not None:
            own = {v.get("id") for v in taken.get("versions") or []}
            extra = [v for v in chapters[idx].get("versions") or [] if v.get("id") not in own]
            if extra:
                taken["versions"] = (taken.get("versions") or []) + extra
            chapters[idx] = taken
            continue
        at = 0
        for prev in reversed(copy_chapters[:i]):
            j = next((k for k, c in enumerate(chapters) if c.get("id") == prev.get("id")), None)
            if j is not None:
                at = j + 1
                break
        chapters.insert(at, taken)
    main["chapters"] = chapters
    # A taken chapter that sat in the main book's bin is back in the book.
    if "deleted_chapters" in main:
        kept = [d for d in main.get("deleted_chapters") or [] if d.get("id") not in wanted]
        if kept:
            main["deleted_chapters"] = kept
        else:
            del main["deleted_chapters"]
    _write(main_path, main)
    return info["base_file"]
