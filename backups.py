"""Local safety net for everything a writer can lose.

Every code path that would overwrite or remove a book, chat transcript or
chapter-digest file — a save, a delete, a rename, a Dropbox pull — first
copies the current bytes here. The rule (CLAUDE.md, "Never lose a book"):
no user data is ever destroyed without a recoverable copy.

Layout (gitignored):
  backups/<kind>/<base>/<YYYY-MM-DD HH.MM.SS> <reason>.json
where <kind> is "books", "chat_history" or "digests" and <base> is the
file's name without ".json". Mirrors ios/Autorino/Persistence/BackupStore.swift.

Retention: every snapshot from the last KEEP_ALL_FOR is kept; older ones are
thinned to the newest per calendar day, which is kept forever. Nothing else
is ever pruned, and a deleted book's last snapshot is always its newest.
"""

import datetime
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
BACKUP_ROOT = os.path.join(_HERE, "backups")

# A routine autosave snapshots at most this often per book; destructive
# events (delete, rename, sync overwrite, shrink, unreadable) always do.
ROUTINE_INTERVAL = datetime.timedelta(minutes=15)
KEEP_ALL_FOR = datetime.timedelta(days=14)
_STAMP_FMT = "%Y-%m-%d %H.%M.%S"
_STAMP_LEN = 19


def _dir_for(kind, base):
    return os.path.join(BACKUP_ROOT, kind, base)


def _parse_stamp(name):
    try:
        return datetime.datetime.strptime(name[:_STAMP_LEN], _STAMP_FMT)
    except ValueError:
        return None


def _snapshots(directory):
    """Snapshot filenames in `directory`, oldest first."""
    try:
        names = [n for n in os.listdir(directory) if n.endswith(".json") and _parse_stamp(n)]
    except FileNotFoundError:
        return []
    return sorted(names)


def snapshot(path, kind, reason, routine=False):
    """Copies `path` into the backup store before the caller overwrites or
    removes it. Returns the snapshot path, or None when nothing needed
    saving (no file, identical to the newest snapshot, or a routine save
    inside ROUTINE_INTERVAL).

    Raises on I/O failure on purpose: a destructive caller must not go ahead
    if its safety copy could not be written. Routine callers catch."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return None
    base = os.path.basename(path)
    if base.endswith(".json"):
        base = base[:-5]
    directory = _dir_for(kind, base)
    os.makedirs(directory, exist_ok=True)
    existing = _snapshots(directory)
    now = datetime.datetime.now()
    if existing:
        newest = existing[-1]
        newest_at = _parse_stamp(newest)
        if routine and newest_at and now - newest_at < ROUTINE_INTERVAL:
            return None
        try:
            with open(os.path.join(directory, newest), "rb") as f:
                if f.read() == data:
                    return None
        except IOError:
            pass
    stamp = now.strftime(_STAMP_FMT)
    dest = os.path.join(directory, f"{stamp} {reason}.json")
    n = 2
    while os.path.exists(dest):
        dest = os.path.join(directory, f"{stamp} {reason} {n}.json")
        n += 1
    tmp = dest + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, dest)
    _prune(directory, now)
    return dest


def store_bytes(data, kind, base, reason):
    """Like snapshot(), for bytes that only exist in memory (e.g. a remote
    file sync could not merge). Always written, never deduplicated away."""
    directory = _dir_for(kind, base)
    os.makedirs(directory, exist_ok=True)
    now = datetime.datetime.now()
    dest = os.path.join(directory, f"{now.strftime(_STAMP_FMT)} {reason}.json")
    n = 2
    while os.path.exists(dest):
        dest = os.path.join(directory, f"{now.strftime(_STAMP_FMT)} {reason} {n}.json")
        n += 1
    with open(dest + ".tmp", "wb") as f:
        f.write(data)
    os.replace(dest + ".tmp", dest)
    return dest


def _prune(directory, now):
    """Older than KEEP_ALL_FOR: keep only the newest snapshot of each day."""
    newest_per_day = {}
    old = []
    for name in _snapshots(directory):
        at = _parse_stamp(name)
        if now - at < KEEP_ALL_FOR:
            continue
        old.append(name)
        newest_per_day[at.date()] = name  # ascending order -> last one wins
    keep = set(newest_per_day.values())
    for name in old:
        if name not in keep:
            try:
                os.remove(os.path.join(directory, name))
            except OSError:
                pass


def list_book_backups():
    """[{base, title, snapshots:[{name, stamp, reason, size}]}], newest first,
    for the restore UI."""
    root = os.path.join(BACKUP_ROOT, "books")
    out = []
    try:
        bases = sorted(os.listdir(root))
    except FileNotFoundError:
        return out
    for base in bases:
        directory = os.path.join(root, base)
        if not os.path.isdir(directory):
            continue
        snaps = []
        for name in reversed(_snapshots(directory)):
            reason = name[_STAMP_LEN:-5].strip()
            snaps.append({
                "name": name,
                "stamp": name[:_STAMP_LEN],
                "reason": reason,
                "size": os.path.getsize(os.path.join(directory, name)),
            })
        if snaps:
            out.append({"base": base, "snapshots": snaps})
    return out


def read_book_snapshot(base, name):
    """Raw bytes of one book snapshot. Rejects path traversal."""
    if os.sep in base or os.sep in name or base.startswith(".") or name.startswith("."):
        raise ValueError("invalid backup name")
    with open(os.path.join(_dir_for("books", base), name), "rb") as f:
        return f.read()


def book_shrank(old_book, new_book):
    """True when `new_book` lost content relative to `old_book`: a chapter,
    character, location, note or event order gone, or the manuscript
    meaningfully shorter. That is what an accidental delete looks like from
    the save path, and it always earns a snapshot regardless of interval."""
    if not isinstance(old_book, dict) or not isinstance(new_book, dict):
        return True
    for key in ("chapters", "characters", "locations", "event_orders", "topics",
                "questions", "passages", "saved_chats"):
        if len(new_book.get(key) or []) < len(old_book.get(key) or []):
            return True
    old_len = sum(len((c or {}).get("content") or "") for c in old_book.get("chapters") or [])
    new_len = sum(len((c or {}).get("content") or "") for c in new_book.get("chapters") or [])
    # Ordinary editing deletes text too; only a large drop is suspicious.
    return old_len > 2000 and new_len < old_len - max(2000, old_len // 20)


def load_json(path):
    """(parsed, ok). ok is False when the file exists but is not valid JSON."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), True
    except FileNotFoundError:
        return None, True
    except (ValueError, UnicodeDecodeError):
        return None, False
