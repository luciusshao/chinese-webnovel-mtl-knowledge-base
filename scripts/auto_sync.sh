#!/usr/bin/env python3
"""
auto_sync.sh — single-entry maintainer script.

Default behaviour:
1. Pull the Google Sheet into LOCAL_WORK_DIR/submissions.csv
2. Merge approved / replace rows into docs/downloads/*.csv
3. Commit glossary CSV changes
4. Push the current branch
5. Delete the handled rows from the Google Sheet

If a conflict is detected, the script aborts before writing, committing, or
deleting anything.
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from string import Template
from typing import Dict, List, Tuple


# ---------------------------------------------------------------------------
# Re-exec inside scripts/.venv if the script was launched with a different
# python interpreter (e.g. ./scripts/auto_sync.sh under system python3).
# This avoids the "missing dependency: gspread" error when users forget to
# activate the venv.  Skipped silently if the venv hasn't been created yet —
# in that case the original ImportError path will guide the user to run
# `python3 -m venv scripts/.venv && scripts/.venv/bin/pip install -r ...`.
#
# We compare sys.prefix (not sys.executable) because system python3 and
# venv/bin/python are often symlinks to the same underlying interpreter,
# so resolving sys.executable would falsely report "already inside venv".
# Inside a venv, sys.prefix points to the venv root; outside it points to
# the base install.
# ---------------------------------------------------------------------------
_VENV_DIR = Path(__file__).resolve().parent / ".venv"
_VENV_PY = _VENV_DIR / "bin" / "python"
if (
    _VENV_PY.exists()
    and Path(sys.prefix).resolve() != _VENV_DIR.resolve()
):
    os.execv(
        str(_VENV_PY),
        [str(_VENV_PY), str(Path(__file__).resolve()), *sys.argv[1:]],
    )


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = Path(__file__).resolve()
SCRIPT_DIR = SCRIPT_PATH.parent
ENV_FILE = REPO_ROOT / "scripts" / ".env"
DOWNLOADS_DIR = REPO_ROOT / "docs" / "downloads"

DEFAULT_LOCAL_WORK_DIR = "~/.config/glossary-sync"
DEFAULT_SHEET_TAB = "Form Responses 1"

PUBLIC_HEADERS = ["genre", "chinese", "preferred_english", "notes"]
VALID_GENRES = {"xianxia", "wuxia", "xiuxian"}
ALLOWED_STATUSES = {"approved", "replace"}


def bootstrap_venv() -> None:
    """Prefer the repo venv automatically when the script is run directly."""
    venv_python = SCRIPT_DIR / ".venv" / "bin" / "python"
    if not venv_python.exists():
        return
    current = Path(sys.executable).resolve()
    desired = venv_python.resolve()
    if current == desired:
        return
    os.execv(str(desired), [str(desired), str(SCRIPT_PATH), *sys.argv[1:]])

SUBMISSION_FIELD_MAP = {
    "genre": "genre",
    "chinese term": "chinese",
    "preferred english": "preferred_english",
    "alternative english": "_alternative",
    "reason or context": "_reason",
    "source novel": "_source",
    "your contact": "_contact",
    "status": "status",
    "reviewer": "reviewer",
    "reviewed_at": "reviewed_at",
    "notes": "_reviewer_notes",
    "timestamp": "_timestamp",
    "_sheet_row": "_sheet_row",
}


class ScriptError(RuntimeError):
    """Raised when the one-shot sync script cannot complete safely."""


@dataclass(frozen=True)
class Settings:
    env_file: Path
    local_work_dir: Path
    inbox_csv: Path
    google_service_account_json: Path
    sheet_id: str
    sheet_tab: str


@dataclass
class Plan:
    inbox_rows: List[Dict[str, str]]
    approved_rows: List[Dict[str, str]]
    skipped_status_count: Dict[str, int]
    additions: Dict[str, List[Dict[str, str]]]
    replacements: List[Tuple[Dict[str, str], Dict[str, str], Path]]
    duplicates: List[Tuple[Dict[str, str], Path]]
    conflicts: List[Tuple[Dict[str, str], Dict[str, str], Path]]
    bad_genre: List[Dict[str, str]]
    existing_cache: Dict[str, List[Dict[str, str]]]


def say(message: str) -> None:
    print(f"▸ {message}")


def ok(message: str) -> None:
    print(f"✓ {message}")


def warn(message: str) -> None:
    print(f"⚠ {message}")


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def expand_value(raw: str, known: Dict[str, str]) -> str:
    merged = dict(os.environ)
    merged.update(known)
    return os.path.expanduser(Template(raw).safe_substitute(merged))


def resolve_path(raw: str, *, base: Path = REPO_ROOT) -> Path:
    expanded = os.path.expanduser(os.path.expandvars(raw))
    path = Path(expanded)
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def load_env() -> Dict[str, str]:
    if not ENV_FILE.exists():
        raise ScriptError(
            "missing scripts/.env\n"
            "   Copy scripts/.env.example to scripts/.env and fill it in."
        )

    out: Dict[str, str] = {}
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        out[key.strip()] = expand_value(value, out)
    return out


def load_settings() -> Settings:
    env = load_env()
    local_work_dir = resolve_path(env.get("LOCAL_WORK_DIR") or DEFAULT_LOCAL_WORK_DIR)
    google_service_account_json = resolve_path(
        env.get("GOOGLE_SERVICE_ACCOUNT_JSON")
        or env.get("SA_KEY_PATH")
        or str(local_work_dir / "service-account.json")
    )
    sheet_id = (env.get("SHEET_ID") or "").strip()
    sheet_tab = (env.get("SHEET_TAB") or DEFAULT_SHEET_TAB).strip() or DEFAULT_SHEET_TAB

    if not sheet_id:
        raise ScriptError("scripts/.env: SHEET_ID is empty. Edit the file and try again.")

    return Settings(
        env_file=ENV_FILE,
        local_work_dir=local_work_dir,
        inbox_csv=(local_work_dir / "submissions.csv").resolve(),
        google_service_account_json=google_service_account_json,
        sheet_id=sheet_id,
        sheet_tab=sheet_tab,
    )


def run_git(cmd: List[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def git_output(cmd: List[str]) -> str:
    result = run_git(cmd)
    if result.returncode != 0:
        raise ScriptError(result.stderr.strip() or result.stdout.strip() or f"git failed: {' '.join(cmd)}")
    return result.stdout.strip()


def ensure_google_clients(settings: Settings):
    if not settings.google_service_account_json.exists():
        raise ScriptError(
            f"service-account key not found: {settings.google_service_account_json}\n"
            "   Check GOOGLE_SERVICE_ACCOUNT_JSON in scripts/.env."
        )

    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError as e:
        raise ScriptError(
            f"missing dependency: {e.name}\n"
            "   Install with:\n"
            "     python3 -m venv scripts/.venv\n"
            "     scripts/.venv/bin/pip install -r scripts/requirements.txt"
        ) from e

    scopes = ["https://www.googleapis.com/auth/spreadsheets"]
    try:
        creds = Credentials.from_service_account_file(
            str(settings.google_service_account_json),
            scopes=scopes,
        )
        gc = gspread.authorize(creds)
        sh = gc.open_by_key(settings.sheet_id)
        return sh.worksheet(settings.sheet_tab)
    except Exception as e:  # noqa: BLE001
        raise ScriptError(f"Google Sheets API error: {e}") from e


def normalise_header(header: str) -> str:
    out = header.strip().lower()
    if out.endswith("*"):
        out = out[:-1].strip()
    if "(" in out:
        out = out.split("(", 1)[0].strip()
    return out


def map_row(raw: Dict[str, str]) -> Dict[str, str]:
    mapped: Dict[str, str] = {}
    for raw_key, raw_val in raw.items():
        if raw_key is None:
            continue
        target = SUBMISSION_FIELD_MAP.get(normalise_header(raw_key))
        if target is None:
            continue
        mapped[target] = (raw_val or "").strip()
    return mapped


def pull_sheet_rows(worksheet, settings: Settings) -> List[Dict[str, str]]:
    rows: List[List[str]] = worksheet.get_all_values()
    if not rows:
        raise ScriptError(f"sheet '{settings.sheet_tab}' is empty (not even a header row)")

    header = list(rows[0])
    full_header = header + ["_sheet_row"]
    output_rows: List[List[str]] = [full_header]
    mapped_rows: List[Dict[str, str]] = []

    for index, row in enumerate(rows[1:], start=2):
        padded = list(row[: len(header)])
        if len(padded) < len(header):
            padded.extend([""] * (len(header) - len(padded)))
        padded.append(str(index))
        output_rows.append(padded)
        mapped_rows.append(map_row({full_header[i]: padded[i] for i in range(len(full_header))}))

    settings.local_work_dir.mkdir(parents=True, exist_ok=True)
    with settings.inbox_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerows(output_rows)

    ok(f"pulled {len(rows) - 1} row(s) from '{settings.sheet_tab}' -> {display_path(settings.inbox_csv)}")
    return mapped_rows


def load_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return [row for row in reader]


def write_csv(path: Path, rows: List[Dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=PUBLIC_HEADERS, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({header: row.get(header, "") for header in PUBLIC_HEADERS})


def backup(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = path.with_suffix(path.suffix + f".bak.{stamp}")
    shutil.copy2(path, bak)
    return bak


def to_public_row(submission: Dict[str, str]) -> Dict[str, str]:
    notes = submission.get("_reviewer_notes") or submission.get("_reason") or ""
    return {
        "genre": (submission.get("genre") or "").lower().strip(),
        "chinese": (submission.get("chinese") or "").strip(),
        "preferred_english": (submission.get("preferred_english") or "").strip(),
        "notes": notes,
        "_status": (submission.get("status") or "").lower().strip(),
        "_sheet_row": (submission.get("_sheet_row") or "").strip(),
    }


def classify(new_row: Dict[str, str], existing: List[Dict[str, str]]) -> Tuple[str, Dict[str, str] | None]:
    chinese = new_row["chinese"]
    english = new_row["preferred_english"].lower()
    for row in existing:
        if row.get("chinese", "").strip() != chinese:
            continue
        existing_english = row.get("preferred_english", "").strip().lower()
        if existing_english == english:
            return ("duplicate", row)
        return ("conflict", row)
    return ("add", None)


def build_plan(inbox_rows: List[Dict[str, str]]) -> Plan:
    approved_rows: List[Dict[str, str]] = []
    skipped_status_count: Dict[str, int] = defaultdict(int)
    for row in inbox_rows:
        status = (row.get("status") or "").strip().lower()
        if status in ALLOWED_STATUSES:
            approved_rows.append(row)
        else:
            skipped_status_count[status or "(empty)"] += 1

    print(f"Filter status in {sorted(ALLOWED_STATUSES)}: kept {len(approved_rows)} of {len(inbox_rows)}")
    for status, count in sorted(skipped_status_count.items()):
        print(f"  · skipped status={status!r}: {count}")
    print()

    additions: Dict[str, List[Dict[str, str]]] = defaultdict(list)
    replacements: List[Tuple[Dict[str, str], Dict[str, str], Path]] = []
    duplicates: List[Tuple[Dict[str, str], Path]] = []
    conflicts: List[Tuple[Dict[str, str], Dict[str, str], Path]] = []
    bad_genre: List[Dict[str, str]] = []
    existing_cache: Dict[str, List[Dict[str, str]]] = {}

    for submission in approved_rows:
        new_row = to_public_row(submission)
        if not new_row["chinese"] or not new_row["preferred_english"]:
            warn(f"invalid row skipped: missing chinese or preferred_english: {submission}")
            continue

        genre = new_row["genre"]
        if genre not in VALID_GENRES:
            bad_genre.append(new_row)
            continue

        target = DOWNLOADS_DIR / f"{genre}-core-terms.csv"
        if genre not in existing_cache:
            existing_cache[genre] = load_csv(target)

        decision, existing = classify(new_row, existing_cache[genre] + additions[genre])
        status = new_row["_status"]

        if decision == "duplicate":
            duplicates.append((new_row, target))
            print(f"  ~ DUP     {genre}/{new_row['chinese']} -> {new_row['preferred_english']!r}")
        elif decision == "conflict":
            if status == "replace":
                replacements.append((new_row, existing, target))
                print(
                    f"  ↻ REPLACE {genre}/{new_row['chinese']}  "
                    f"{existing.get('preferred_english')!r} -> {new_row['preferred_english']!r}"
                )
            else:
                conflicts.append((new_row, existing, target))
                print(
                    f"  ! CLASH   {genre}/{new_row['chinese']}  "
                    f"existing={existing.get('preferred_english')!r}  "
                    f"submitted={new_row['preferred_english']!r}"
                )
        else:
            additions[genre].append(new_row)
            print(f"  + ADD     {genre}/{new_row['chinese']} -> {new_row['preferred_english']!r}")

    print()
    if bad_genre:
        warn(f"{len(bad_genre)} row(s) had an unsupported genre and were skipped")
        for row in bad_genre:
            print(f"    genre={row['genre']!r} chinese={row['chinese']!r}")
        print()

    if additions or replacements:
        print("Plan per-file:")
        per_file: Dict[str, Dict[str, int]] = defaultdict(lambda: {"add": 0, "replace": 0})
        for genre, rows in additions.items():
            per_file[genre]["add"] += len(rows)
        for row, _existing, _target in replacements:
            per_file[row["genre"]]["replace"] += 1
        for genre, counts in sorted(per_file.items()):
            parts: List[str] = []
            if counts["add"]:
                parts.append(f"+{counts['add']} new")
            if counts["replace"]:
                parts.append(f"~{counts['replace']} replaced")
            print(f"  {display_path(DOWNLOADS_DIR / f'{genre}-core-terms.csv')}: {' / '.join(parts)}")
    else:
        print("Nothing to add or replace.")

    if conflicts:
        print()
        print("Conflicts detected. Change the row status in the Sheet and re-run:")
        print("  · use 'replace' to overwrite the existing English")
        print("  · use 'rejected' to keep the existing English")

    return Plan(
        inbox_rows=inbox_rows,
        approved_rows=approved_rows,
        skipped_status_count=dict(skipped_status_count),
        additions=additions,
        replacements=replacements,
        duplicates=duplicates,
        conflicts=conflicts,
        bad_genre=bad_genre,
        existing_cache=existing_cache,
    )


def apply_plan(plan: Plan) -> Tuple[List[int], List[str]]:
    if plan.conflicts:
        raise ScriptError("sync aborted because the Sheet still has CLASH rows")

    for new_row, existing, _target in plan.replacements:
        old_english = (existing.get("preferred_english") or "").strip()
        existing["preferred_english"] = new_row["preferred_english"]
        notes_parts: List[str] = []
        if new_row.get("notes", "").strip():
            notes_parts.append(new_row["notes"].strip())
        if old_english and old_english.lower() != new_row["preferred_english"].lower():
            notes_parts.append(f"was: {old_english}")
        previous_notes = (existing.get("notes") or "").strip()
        if previous_notes:
            notes_parts.append(f"(prev: {previous_notes})")
        existing["notes"] = "; ".join(notes_parts)

    modified_genres = (
        {genre for genre, rows in plan.additions.items() if rows}
        | {row["genre"] for row, _existing, _target in plan.replacements}
    )
    changed_paths: List[str] = []

    if modified_genres:
        print()
        say("writing glossary CSV files")
        for genre in sorted(modified_genres):
            target = DOWNLOADS_DIR / f"{genre}-core-terms.csv"
            if target.exists():
                bak = backup(target)
                print(f"  💾 backup: {display_path(bak)}")
            merged_rows = plan.existing_cache[genre] + plan.additions.get(genre, [])
            write_csv(target, merged_rows)
            changed_paths.append(str(target.relative_to(REPO_ROOT)))
            print(
                f"  ✓ wrote {display_path(target)}  "
                f"(+{len(plan.additions.get(genre, []))} new, "
                f"~{sum(1 for row, _, _ in plan.replacements if row['genre'] == genre)} replaced, "
                f"total {len(merged_rows)})"
            )
    else:
        say("no CSV writes needed for this run")

    handled_rows: List[int] = []
    for rows in plan.additions.values():
        for row in rows:
            if row.get("_sheet_row"):
                handled_rows.append(int(row["_sheet_row"]))
    for row, _existing, _target in plan.replacements:
        if row.get("_sheet_row"):
            handled_rows.append(int(row["_sheet_row"]))
    for row, _target in plan.duplicates:
        if row.get("_sheet_row"):
            handled_rows.append(int(row["_sheet_row"]))
    return handled_rows, changed_paths


def commit_and_push(changed_paths: List[str], *, add_count: int, replace_count: int, dry_run: bool) -> None:
    if not changed_paths:
        say("no glossary CSV changes to commit")
        return

    if dry_run:
        say("dry-run: skipping git commit/push")
        return

    say("committing glossary CSVs")
    add_result = run_git(["git", "add", "--", *changed_paths])
    if add_result.returncode != 0:
        raise ScriptError(add_result.stderr.strip() or add_result.stdout.strip() or "git add failed")

    diff_result = run_git(["git", "diff", "--cached", "--quiet", "--", *changed_paths])
    if diff_result.returncode == 0:
        say("glossary CSVs already match HEAD; skipping commit/push")
        return
    if diff_result.returncode not in {0, 1}:
        raise ScriptError(diff_result.stderr.strip() or diff_result.stdout.strip() or "git diff failed")

    parts: List[str] = []
    if add_count:
        parts.append(f"add {add_count} term(s)")
    if replace_count:
        parts.append(f"replace {replace_count} term(s)")
    subject = f"glossary: {', '.join(parts)} from submissions" if parts else "glossary: sync submissions"

    commit_result = run_git(
        [
            "git",
            "commit",
            "--only",
            "-m",
            subject,
            "-m",
            "Auto-synced from Google Sheet submissions via scripts/auto_sync.sh.",
            "--",
            *changed_paths,
        ]
    )
    if commit_result.returncode != 0:
        raise ScriptError(commit_result.stderr.strip() or commit_result.stdout.strip() or "git commit failed")

    branch = git_output(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    say(f"pushing to origin/{branch}")
    push_result = run_git(["git", "push", "origin", branch])
    if push_result.returncode != 0:
        raise ScriptError(push_result.stderr.strip() or push_result.stdout.strip() or "git push failed")
    ok("git push complete")


def delete_sheet_rows(worksheet, handled_rows: List[int], *, dry_run: bool) -> None:
    if not handled_rows:
        say("no handled Sheet rows to delete")
        return

    rows_sorted = sorted(set(handled_rows), reverse=True)
    if dry_run:
        say(f"dry-run: would delete Sheet rows {sorted(rows_sorted)}")
        return

    say("deleting handled rows from Google Sheet")
    deleted: List[int] = []
    try:
        for row_number in rows_sorted:
            worksheet.delete_rows(row_number)
            deleted.append(row_number)
    except Exception as e:  # noqa: BLE001
        raise ScriptError(
            f"Google Sheets API error while deleting rows: {e}\n"
            f"   deleted so far: {deleted}\n"
            f"   remaining: {[row for row in rows_sorted if row not in deleted]}"
        ) from e
    ok(f"deleted {len(deleted)} handled row(s) from '{worksheet.title}'")


def main(argv: List[str] | None = None) -> int:
    bootstrap_venv()

    parser = argparse.ArgumentParser(
        description="Pull approved glossary submissions, commit glossary CSVs, push, and delete handled Sheet rows.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Refresh the Sheet snapshot and show the plan only. Do not write glossary CSVs, commit, push, or delete Sheet rows.",
    )
    args = parser.parse_args(argv)

    settings = load_settings()

    say(f"using config: {display_path(settings.env_file)}")
    say(f"local work dir: {settings.local_work_dir}")

    worksheet = ensure_google_clients(settings)
    inbox_rows = pull_sheet_rows(worksheet, settings)
    plan = build_plan(inbox_rows)

    add_count = sum(len(rows) for rows in plan.additions.values())
    replace_count = len(plan.replacements)
    duplicate_count = len(plan.duplicates)
    say(
        f"summary: {add_count} add, {replace_count} replace, {duplicate_count} dup, {len(plan.conflicts)} clash"
    )

    if args.dry_run:
        say("dry-run complete")
        return 0

    handled_rows, changed_paths = apply_plan(plan)
    commit_and_push(
        changed_paths,
        add_count=add_count,
        replace_count=replace_count,
        dry_run=False,
    )

    delete_sheet_rows(worksheet, handled_rows, dry_run=False)
    ok("done")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ScriptError as error:
        raise SystemExit(f"✗ {error}") from error
