#!/usr/bin/env python3
"""
sync.py — Merge approved glossary submissions from a Google Sheet export
into the public CSV files served by the site.

Usage
-----
    # Dry-run (default — shows plan, writes nothing):
    python3 scripts/sync.py

    # Actually write changes (with auto-backup of the target CSVs):
    python3 scripts/sync.py --apply

    # Custom inbox file:
    python3 scripts/sync.py --inbox path/to/responses.csv --apply

Inputs
------
- scripts/inbox/submissions.csv  (Google Sheet → File → Download → CSV)
- docs/downloads/<genre>-core-terms.csv  (existing public glossaries)

Behaviour
---------
- Only rows whose `status` column is `approved` or `replace` are processed.
  Everything else (rejected / dup / merged / pending / blank) is ignored,
  so the reviewer never has to manually de-duplicate against existing CSVs.
- Rows are routed to the CSV that matches their `genre` column.
  Unknown genres are skipped with a warning.
- Conflict handling:
    * Same (genre, chinese) AND same preferred_english → silently skipped (DUP).
    * Same (genre, chinese) BUT different preferred_english:
        · status=approved → reported as CLASH and *not* written. The reviewer
          should change status to `replace` (to overwrite) or `rejected`
          (to keep the existing English) and re-run.
        · status=replace  → the existing row's preferred_english is OVERWRITTEN
          and the old value is archived into the notes column
          (e.g. "was: cave residence; <reviewer notes>").
    * Otherwise (fresh chinese) → appended to the corresponding CSV.
- A `.bak` copy of every modified CSV is created in the same directory before
  writing, so accidental clobbers can be reverted.
- The script never edits the inbox file or the Google Sheet itself.

Zero dependencies — Python 3.7+ stdlib only.
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple


REPO_ROOT = Path(__file__).resolve().parent.parent
DOWNLOADS_DIR = REPO_ROOT / "docs" / "downloads"
DEFAULT_INBOX = REPO_ROOT / "scripts" / "inbox" / "submissions.csv"

# CSV column order used by the public glossary files. Do NOT reorder.
PUBLIC_HEADERS = ["genre", "chinese", "preferred_english", "notes"]

# Map known Google Form question titles → public CSV column names.
# The match is case-insensitive and tolerates trailing "*", "(optional)", etc.
SUBMISSION_FIELD_MAP = {
    "genre": "genre",
    "chinese term": "chinese",
    "preferred english": "preferred_english",
    "alternative english": "_alternative",  # deprecated form field, still accepted
    "reason or context": "_reason",          # may become `notes` if reviewer left no override
    "source novel": "_source",               # informational only; not written to CSV
    "your contact": "_contact",              # informational only; not written to CSV
    "status": "status",
    "reviewer": "reviewer",
    "reviewed_at": "reviewed_at",
    "notes": "_reviewer_notes",              # reviewer-supplied notes (preferred over _reason)
    "timestamp": "_timestamp",
}

VALID_GENRES = {"xianxia", "wuxia", "xiuxian"}
# `other` and friends will be reported but not auto-written; reviewer should
# pick a real genre or extend this list.

# Sheet `status` values that the reviewer uses to gate a row through:
#   approved — append a fresh term; refuse to overwrite anything (CLASH if
#              same chinese is already in the CSV with a different English).
#   replace  — like approved, but if the chinese already exists with a
#              DIFFERENT preferred_english, OVERWRITE that row's English and
#              archive the old value into the notes column.
# Anything else (rejected / dup / merged / pending / blank) is ignored.
ALLOWED_STATUSES = {"approved", "replace"}

ANSI = {
    "g":  "\033[32m",
    "y":  "\033[33m",
    "r":  "\033[31m",
    "b":  "\033[34m",
    "m":  "\033[35m",
    "d":  "\033[2m",
    "x":  "\033[0m",
}


def color(s: str, c: str) -> str:
    if not sys.stdout.isatty():
        return s
    return f"{ANSI[c]}{s}{ANSI['x']}"


# --------------------------------------------------------------------------
# Reading helpers
# --------------------------------------------------------------------------

def normalise_header(h: str) -> str:
    """Lowercase, strip, drop trailing required-marker / parenthetical hint."""
    out = h.strip().lower()
    # Drop a trailing " *" or " (...)"
    if out.endswith("*"):
        out = out[:-1].strip()
    if "(" in out:
        out = out.split("(", 1)[0].strip()
    return out


def map_row(raw: Dict[str, str]) -> Dict[str, str]:
    """Translate a Google-Sheet-style row into our internal field names."""
    mapped: Dict[str, str] = {}
    for raw_key, raw_val in raw.items():
        if raw_key is None:
            continue
        key = normalise_header(raw_key)
        target = SUBMISSION_FIELD_MAP.get(key)
        if target is None:
            # unknown column — keep under its raw key, we may need it for diagnostics
            mapped.setdefault("_extra", {})
            mapped["_extra"][key] = (raw_val or "").strip()
            continue
        mapped[target] = (raw_val or "").strip()
    return mapped


def load_inbox(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        sys.exit(color(f"✗ inbox file not found: {path}", "r"))
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        rows = [map_row(r) for r in reader]
    return rows


def load_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return [r for r in reader]


def write_csv(path: Path, rows: List[Dict[str, str]]) -> None:
    # Quote-as-needed (default) — minimal noise in diffs.
    # Force LF line endings to match the existing repo files (csv module defaults to CRLF).
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=PUBLIC_HEADERS, lineterminator="\n")
        writer.writeheader()
        for r in rows:
            writer.writerow({h: r.get(h, "") for h in PUBLIC_HEADERS})


def backup(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = path.with_suffix(path.suffix + f".bak.{stamp}")
    shutil.copy2(path, bak)
    return bak


# --------------------------------------------------------------------------
# Decision logic
# --------------------------------------------------------------------------

def to_public_row(submission: Dict[str, str]) -> Dict[str, str]:
    """Convert a mapped submission into a row matching PUBLIC_HEADERS.

    The leading-underscore field `_status` is carried through for the
    dispatcher in main(); write_csv() ignores it (only PUBLIC_HEADERS are
    written), so it never leaks to disk.
    """
    notes = submission.get("_reviewer_notes") or submission.get("_reason") or ""
    return {
        "genre":             (submission.get("genre") or "").lower().strip(),
        "chinese":           (submission.get("chinese") or "").strip(),
        "preferred_english": (submission.get("preferred_english") or "").strip(),
        "notes":             notes,
        "_status":           (submission.get("status") or "").lower().strip(),
    }


def classify(new_row: Dict[str, str], existing: List[Dict[str, str]]) -> Tuple[str, Dict[str, str] | None]:
    """
    Returns (decision, conflicting_existing_row_or_None) where decision is one of:
        - 'add'       — fresh entry, append it
        - 'duplicate' — same chinese + same preferred_english already exists
        - 'conflict'  — same chinese, but different preferred_english
    Match is case-sensitive on Chinese (different chars are different terms),
    case-insensitive on English (so 'Heavenly Tribulation' == 'heavenly tribulation').
    """
    chi = new_row["chinese"]
    en  = new_row["preferred_english"].lower()
    for r in existing:
        if r.get("chinese", "").strip() == chi:
            existing_en = r.get("preferred_english", "").strip().lower()
            if existing_en == en:
                return ("duplicate", r)
            return ("conflict", r)
    return ("add", None)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="Merge approved Google Sheet submissions into glossary CSVs.")
    p.add_argument("--inbox", type=Path, default=DEFAULT_INBOX,
                   help=f"Path to the Google Sheet CSV export (default: {DEFAULT_INBOX.relative_to(REPO_ROOT)})")
    p.add_argument("--apply", action="store_true",
                   help="Actually write changes. Without --apply this is a dry-run.")
    p.add_argument("--include-genre", action="append", default=[],
                   help="Allow an extra genre (e.g. --include-genre other). Repeatable.")
    args = p.parse_args()

    # Resolve inbox to absolute so relative_to(REPO_ROOT) works regardless of CWD.
    args.inbox = args.inbox.resolve()

    inbox_rows = load_inbox(args.inbox)
    valid_genres = set(VALID_GENRES) | {g.lower() for g in args.include_genre}

    def show(p: Path) -> str:
        try:
            return str(p.relative_to(REPO_ROOT))
        except ValueError:
            return str(p)

    print(color(f"📥 inbox:   {show(args.inbox)}  ({len(inbox_rows)} row(s))", "b"))
    print(color(f"📤 output:  {show(DOWNLOADS_DIR)}/", "b"))
    print(color(f"🟢 mode:    {'APPLY (will write)' if args.apply else 'DRY-RUN (no writes)'}", "b"))
    print()

    # Filter to rows the reviewer has gated through (approved / replace).
    approved = []
    skipped_status_count = defaultdict(int)
    for row in inbox_rows:
        status = (row.get("status") or "").strip().lower()
        if status in ALLOWED_STATUSES:
            approved.append(row)
        else:
            skipped_status_count[status or "(empty)"] += 1

    print(color(
        f"Filter status in {sorted(ALLOWED_STATUSES)}: kept {len(approved)} of {len(inbox_rows)}",
        "d",
    ))
    if skipped_status_count:
        for s, n in sorted(skipped_status_count.items()):
            print(color(f"  · skipped status={s!r}: {n}", "d"))
    print()

    # Group by genre, classify against existing CSV
    additions: Dict[str, List[Dict[str, str]]] = defaultdict(list)
    # replacements carry references INTO existing_cache[genre], so mutating
    # them is enough — they will be picked up at write time.
    replacements: List[Tuple[Dict[str, str], Dict[str, str], Path]] = []
    conflicts: List[Tuple[Dict[str, str], Dict[str, str], Path]] = []
    duplicates: List[Tuple[Dict[str, str], Path]] = []
    bad_genre: List[Dict[str, str]] = []

    # Lazy-load each target CSV once
    existing_cache: Dict[str, List[Dict[str, str]]] = {}

    for sub in approved:
        new_row = to_public_row(sub)
        if not new_row["chinese"] or not new_row["preferred_english"]:
            print(color(f"  ✗ INVALID  missing chinese or preferred_english: {sub}", "r"))
            continue

        genre = new_row["genre"]
        if genre not in valid_genres:
            bad_genre.append(new_row)
            continue

        target = DOWNLOADS_DIR / f"{genre}-core-terms.csv"
        if genre not in existing_cache:
            existing_cache[genre] = load_csv(target)

        sub_status = new_row["_status"]
        decision, existing = classify(new_row, existing_cache[genre] + additions[genre])

        if decision == "duplicate":
            # Same chinese + same English already in CSV. Both `approved`
            # and `replace` mean "no-op" here.
            duplicates.append((new_row, target))
            print(f"  {color('~', 'y')} DUP    {genre}/{new_row['chinese']} → {new_row['preferred_english']!r}  (already present)")
        elif decision == "conflict":
            # Same chinese, different English.
            if sub_status == "replace":
                # Promote: overwrite the existing row's English and archive
                # the old value into notes.
                replacements.append((new_row, existing, target))
                print(
                    f"  {color('↻', 'b')} REPLACE {genre}/{new_row['chinese']}  "
                    f"{existing.get('preferred_english')!r} → {new_row['preferred_english']!r}"
                )
            else:
                conflicts.append((new_row, existing, target))
                print(
                    f"  {color('!', 'r')} CLASH  {genre}/{new_row['chinese']}  "
                    f"existing={existing.get('preferred_english')!r}  "
                    f"submitted={new_row['preferred_english']!r}  "
                    f"{color('(set status=replace to override)', 'd')}"
                )
        else:  # add
            additions[genre].append(new_row)
            print(f"  {color('+', 'g')} ADD    {genre}/{new_row['chinese']} → {new_row['preferred_english']!r}")

    if bad_genre:
        print()
        print(color(f"⚠ {len(bad_genre)} row(s) had a genre outside {sorted(valid_genres)} — skipped:", "y"))
        for r in bad_genre:
            print(f"   genre={r['genre']!r}  chinese={r['chinese']!r}")
        print(color("   (use --include-genre <name> if you want to allow it)", "d"))

    # ---------- plan summary ----------
    print()
    if not additions and not replacements:
        print(color("Nothing to add or replace.", "d"))
    else:
        print(color("Plan per-file:", "b"))
        per_file: Dict[str, Dict[str, int]] = defaultdict(lambda: {"add": 0, "replace": 0})
        for genre, rows in additions.items():
            per_file[genre]["add"] += len(rows)
        for new_row, _existing, _target in replacements:
            per_file[new_row["genre"]]["replace"] += 1
        for genre, counts in sorted(per_file.items()):
            if not counts["add"] and not counts["replace"]:
                continue
            target = DOWNLOADS_DIR / f"{genre}-core-terms.csv"
            bits = []
            if counts["add"]:
                bits.append(f"+{counts['add']} new")
            if counts["replace"]:
                bits.append(f"~{counts['replace']} replaced")
            print(f"  {show(target)}: {' / '.join(bits)}")

    if conflicts:
        print()
        print(color(f"⛔ {len(conflicts)} conflict(s) NOT written. To resolve, in the Google Sheet:", "r"))
        print(color("   · keep the existing English   → set status=rejected", "d"))
        print(color("   · adopt the submitted English → change status from approved to replace", "d"))
        print(color("   then re-run sync.py.", "d"))

    if not args.apply:
        print()
        print(color("Dry-run finished. Re-run with --apply to write the changes.", "y"))
        return 0

    if not additions and not replacements:
        return 0

    # ---------- apply: replacements first (mutate cache), then write ----------

    # Replacements mutate rows that live inside existing_cache[genre], so the
    # final write will see the new values automatically.
    for new_row, existing, _target in replacements:
        old_english = (existing.get("preferred_english") or "").strip()
        existing["preferred_english"] = new_row["preferred_english"]
        notes_parts: List[str] = []
        if new_row.get("notes", "").strip():
            notes_parts.append(new_row["notes"].strip())
        if old_english and old_english.lower() != new_row["preferred_english"].lower():
            notes_parts.append(f"was: {old_english}")
        prior = (existing.get("notes") or "").strip()
        if prior:
            notes_parts.append(f"(prev: {prior})")
        existing["notes"] = "; ".join(notes_parts)

    print()
    print(color("Writing…", "b"))
    modified_genres = set(additions.keys()) | {row["genre"] for row, _, _ in replacements}
    for genre in sorted(modified_genres):
        target = DOWNLOADS_DIR / f"{genre}-core-terms.csv"
        if target.exists():
            bak = backup(target)
            print(color(f"  💾 backup: {show(bak)}", "d"))
        merged = existing_cache[genre] + additions.get(genre, [])
        write_csv(target, merged)
        add_n = len(additions.get(genre, []))
        repl_n = sum(1 for r, _, _ in replacements if r["genre"] == genre)
        print(color(
            f"  ✓ wrote {show(target)}  (+{add_n} new, ~{repl_n} replaced, total {len(merged)})",
            "g",
        ))

    print()
    print(color("Done. Recommended next steps:", "b"))
    print("  1. git diff docs/downloads/")
    print("  2. (optional) preview locally: docker restart jekyll-preview && open http://localhost:4000/glossary-browser.html")
    print("  3. git add docs/downloads/*.csv && git commit -m 'glossary: add N terms from submissions'")
    print("  4. git push")
    print()
    print(color("Then in Google Sheet, flip the just-pushed rows to status=merged so the next run skips them.", "d"))

    return 0


if __name__ == "__main__":
    sys.exit(main())
