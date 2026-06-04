#!/usr/bin/env python3
"""
pull_sheet.py — Download the Google Sheet of glossary submissions to
                scripts/inbox/submissions.csv so that sync.py can pick it up.

Usage
-----
    # First-time setup:
    cp scripts/.env.example scripts/.env
    # Fill in SHEET_ID and SA_KEY_PATH inside scripts/.env, then:
    python3 -m venv scripts/.venv
    scripts/.venv/bin/pip install -r scripts/requirements.txt

    # Routine use:
    scripts/.venv/bin/python scripts/pull_sheet.py
        → writes scripts/inbox/submissions.csv

What this script does NOT do
----------------------------
- It does not edit the Google Sheet.
- It does not call sync.py or git.  scripts/auto_sync.sh chains them.

Auth
----
- Service Account flow only (simpler, no token refresh dance).
- The SA's client_email must be shared with the Sheet (read-only is enough).

Exit codes
----------
- 0 success
- 1 missing or malformed config (.env, key file, sheet)
- 2 network / API error
"""

from __future__ import annotations

import csv
import os
import sys
from pathlib import Path
from typing import Dict, List


REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / "scripts" / ".env"
DEFAULT_OUT = REPO_ROOT / "scripts" / "inbox" / "submissions.csv"


def load_env(path: Path) -> Dict[str, str]:
    """Tiny .env parser. No dependency on python-dotenv."""
    if not path.exists():
        sys.exit(
            f"✗ missing {path.relative_to(REPO_ROOT)}\n"
            f"   Copy scripts/.env.example to scripts/.env and fill it in."
        )
    out: Dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip().strip('"').strip("'")
    return out


def require(env: Dict[str, str], key: str) -> str:
    val = env.get(key, "").strip()
    if not val:
        sys.exit(f"✗ scripts/.env: {key} is empty. Edit the file and try again.")
    return val


def expand(p: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(p))).resolve()


def main() -> int:
    env = load_env(ENV_FILE)
    sheet_id = require(env, "SHEET_ID")
    sheet_tab = env.get("SHEET_TAB", "Form Responses 1").strip() or "Form Responses 1"
    sa_key_path = expand(require(env, "SA_KEY_PATH"))

    if not sa_key_path.exists():
        sys.exit(
            f"✗ service-account key not found: {sa_key_path}\n"
            f"   Check SA_KEY_PATH in scripts/.env."
        )

    # Defer imports so that --help works even before pip install.
    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError as e:
        sys.exit(
            f"✗ missing dependency: {e.name}\n"
            f"   Install with:\n"
            f"     python3 -m venv scripts/.venv\n"
            f"     scripts/.venv/bin/pip install -r scripts/requirements.txt"
        )

    scopes = ["https://www.googleapis.com/auth/spreadsheets.readonly"]
    try:
        creds = Credentials.from_service_account_file(str(sa_key_path), scopes=scopes)
        gc = gspread.authorize(creds)
        sh = gc.open_by_key(sheet_id)
        ws = sh.worksheet(sheet_tab)
        rows: List[List[str]] = ws.get_all_values()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"✗ Google Sheets API error: {e}")

    if not rows:
        sys.exit(f"✗ sheet '{sheet_tab}' is empty (not even a header row).")

    DEFAULT_OUT.parent.mkdir(parents=True, exist_ok=True)
    with DEFAULT_OUT.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerows(rows)

    n_data = len(rows) - 1  # minus header
    print(
        f"✓ pulled {n_data} row(s) from '{sheet_tab}' "
        f"→ {DEFAULT_OUT.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
