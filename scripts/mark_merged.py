#!/usr/bin/env python3
"""
mark_merged.py — After auto_sync.sh has successfully synced a batch of
glossary changes, REMOVE the corresponding rows from the Google Sheet so
they don't show up in the review queue again.

Reads the row numbers written by sync.py to /tmp/glossary-sync-merged-rows.txt.

Auth & scope
------------
- Uses the same Service Account JSON key as pull_sheet.py.
- Requests the FULL `spreadsheets` scope (read+write). The Sheet must be
  shared with the SA's client_email as Editor (not Viewer).
- pull_sheet.py keeps its read-only scope intact — these are two separate
  authorize() calls, so a leaked SA key still can't read sheets that
  haven't been explicitly shared with it.

Behaviour
---------
- For each row number in the input file, deletes that row from the Sheet.
- Rows are deleted in DESCENDING order to avoid index shifting; deleting
  row 5 first then row 3 is safe — deleting row 3 first would make the
  original row 5 become row 4.
- Rejected / pending / CLASH'd rows are NOT in the input file (sync.py
  only records ADD / REPLACE / DUP). So this script never deletes audit
  trail for things you decided NOT to publish.
- Idempotent against transient failure: deletes the input file only after
  a successful API call, so a partial-failure can be retried.
- Google Sheets keeps full version history (File → Version history), so
  an accidental delete is recoverable from the Sheets UI.

Exit codes
----------
- 0 success (or nothing to delete — file missing / empty)
- 1 missing config / missing key file / unexpected sheet shape
- 2 Sheets API error
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Dict, List


REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / "scripts" / ".env"
MERGED_ROWS_FILE = Path("/tmp/glossary-sync-merged-rows.txt")


def load_env(path: Path) -> Dict[str, str]:
    if not path.exists():
        sys.exit(f"✗ missing {path.relative_to(REPO_ROOT)}")
    out: Dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def require(env: Dict[str, str], key: str) -> str:
    val = env.get(key, "").strip()
    if not val:
        sys.exit(f"✗ scripts/.env: {key} is empty.")
    return val


def expand(p: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(p))).resolve()


def main() -> int:
    if not MERGED_ROWS_FILE.exists():
        # Nothing to mark — sync.py didn't make any changes this run.
        return 0

    raw = MERGED_ROWS_FILE.read_text(encoding="utf-8").strip()
    if not raw:
        # Empty file — same as missing.
        try:
            MERGED_ROWS_FILE.unlink()
        except OSError:
            pass
        return 0

    rows_to_mark: List[int] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows_to_mark.append(int(line))
        except ValueError:
            print(f"⚠ skipping non-numeric row id: {line!r}")
    if not rows_to_mark:
        return 0

    env = load_env(ENV_FILE)
    sheet_id = require(env, "SHEET_ID")
    sheet_tab = env.get("SHEET_TAB", "Form Responses 1").strip() or "Form Responses 1"
    sa_key_path = expand(require(env, "SA_KEY_PATH"))
    if not sa_key_path.exists():
        sys.exit(f"✗ service-account key not found: {sa_key_path}")

    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError as e:
        sys.exit(f"✗ missing dependency: {e.name} (pip install -r scripts/requirements.txt)")

    # READ+WRITE scope — the Sheet must have the SA's email shared as Editor.
    scopes = ["https://www.googleapis.com/auth/spreadsheets"]
    try:
        creds = Credentials.from_service_account_file(str(sa_key_path), scopes=scopes)
        gc = gspread.authorize(creds)
        sh = gc.open_by_key(sheet_id)
        ws = sh.worksheet(sheet_tab)
    except Exception as e:  # noqa: BLE001
        sys.exit(f"✗ Google Sheets API error (open): {e}")

    # Delete in DESCENDING order so earlier deletes don't shift later indices.
    rows_sorted = sorted(set(rows_to_mark), reverse=True)
    deleted: List[int] = []
    try:
        for r in rows_sorted:
            ws.delete_rows(r)
            deleted.append(r)
    except Exception as e:  # noqa: BLE001
        # Partial failure: keep the trigger file around with the rows we
        # haven't deleted yet, so a retry will pick up where we left off.
        remaining = [r for r in rows_sorted if r not in deleted]
        if remaining:
            try:
                MERGED_ROWS_FILE.write_text(
                    "\n".join(str(r) for r in remaining) + "\n",
                    encoding="utf-8",
                )
            except OSError:
                pass
        sys.exit(
            f"✗ Google Sheets API error (delete): {e}\n"
            f"   deleted so far: {deleted}\n"
            f"   remaining queued for next retry: {remaining}"
        )

    print(
        f"✓ deleted {len(deleted)} row(s) from tab '{sheet_tab}': "
        f"original row numbers {sorted(deleted)}"
    )

    # Consume the trigger file so a stray re-run doesn't replay the same
    # set of row numbers against a sheet that has already changed.
    try:
        MERGED_ROWS_FILE.unlink()
    except OSError:
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
