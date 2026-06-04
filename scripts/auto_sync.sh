#!/usr/bin/env bash
# auto_sync.sh — One-shot weekly chore: pull Sheet → sync.py → git commit + push.
#
# Routine:
#   1. Mark rows status=approved/rejected/dup/etc. in the Google Sheet.
#   2. Run this script.
#   3. Done — site updates within ~1 minute via GitHub Pages.
#
# Safety guards:
#   - Refuses to run if the working tree has unrelated staged/unstaged changes,
#     so we never accidentally bundle WIP into the auto-commit.
#   - Only stages docs/downloads/*.csv. Nothing else.
#   - If sync.py reports a CLASH, we stop *before* commit so you can fix it.
#   - Push only happens after a successful commit.
#
# Override knobs (env vars):
#   PYTHON          path to python (defaults to scripts/.venv/bin/python, then python3)
#   SKIP_PUSH=1     run everything except git push (for trial runs)
#   AUTO_SYNC_BRANCH branch to push to (defaults to current branch)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[34m'
  C_D=$'\033[2m'; C_X=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_X=''
fi
say()  { printf '%s\n' "${C_B}▸ $*${C_X}"; }
ok()   { printf '%s\n' "${C_G}✓ $*${C_X}"; }
warn() { printf '%s\n' "${C_Y}⚠ $*${C_X}"; }
die()  { printf '%s\n' "${C_R}✗ $*${C_X}" 1>&2; exit 1; }

# --- pick python -----------------------------------------------------------
if [[ -z "${PYTHON:-}" ]]; then
  if [[ -x "scripts/.venv/bin/python" ]]; then
    PYTHON="scripts/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON="python3"
  else
    die "no python interpreter found. Install python3 or create scripts/.venv."
  fi
fi
say "using python: $PYTHON"

# --- sanity: clean working tree (besides our own outputs) ------------------
# We'll touch only docs/downloads/*.csv. If anything *else* is dirty, bail.
dirty="$(git status --porcelain | grep -Ev '^\?\?\s+docs/downloads/.*\.bak\.' | grep -Ev '^.{2}\s+docs/downloads/.*\.csv$' || true)"
if [[ -n "$dirty" ]]; then
  warn "working tree has unrelated changes:"
  printf '%s\n' "$dirty" | sed 's/^/   /'
  die "commit, stash or revert them first. Aborting."
fi

# --- 1. pull Sheet ---------------------------------------------------------
say "step 1/4 — pulling Google Sheet"
"$PYTHON" scripts/pull_sheet.py

# --- 2. sync (dry-run) so the human can eyeball -----------------------------
say "step 2/4 — sync.py dry-run"
"$PYTHON" scripts/sync.py | tee /tmp/glossary-sync-plan.txt

# Bail early if sync would yield CLASH
if grep -qE '^\s*!? *CLASH' /tmp/glossary-sync-plan.txt; then
  die "sync.py reported CLASH(es). To overwrite the existing English, change status from 'approved' to 'replace' in the Sheet. To keep the existing, set status=rejected. Then re-run."
fi

# Count outcomes from the dry-run plan.
add_count="$(grep -cE '^\s*\+? *ADD\b' /tmp/glossary-sync-plan.txt || true)"
replace_count="$(grep -cE '^\s*↻? *REPLACE\b' /tmp/glossary-sync-plan.txt || true)"
dup_count="$(grep -cE '^\s*~? *DUP\b' /tmp/glossary-sync-plan.txt || true)"
csv_changes=$((add_count + replace_count))
total_actions=$((add_count + replace_count + dup_count))

if [[ "$total_actions" -eq 0 ]]; then
  ok "nothing new to merge or clean up. Exiting cleanly."
  rm -f /tmp/glossary-sync-plan.txt
  exit 0
fi

# --- 3. apply --------------------------------------------------------------
say "step 3/5 — applying ($add_count new, $replace_count replaced, $dup_count dup)"
"$PYTHON" scripts/sync.py --apply

# --- 4. commit + push (only if CSVs actually changed) ----------------------
git add 'docs/downloads/*.csv'

if git diff --cached --quiet; then
  if [[ "$csv_changes" -gt 0 ]]; then
    warn "sync.py --apply ran but produced no diff (rows must already match). Nothing to commit."
  else
    say "step 4/5 — DUP-only run, skipping commit/push"
  fi
else
  say "step 4/5 — committing"
  parts=()
  [[ "$add_count" -gt 0 ]] && parts+=("add $add_count term(s)")
  [[ "$replace_count" -gt 0 ]] && parts+=("replace $replace_count term(s)")
  msg="glossary: $(IFS=', '; echo "${parts[*]}") from submissions"
  git commit -m "$msg" \
    -m "Auto-merged from Google Sheet submissions via scripts/auto_sync.sh." \
    -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

  if [[ "${SKIP_PUSH:-0}" == "1" ]]; then
    warn "SKIP_PUSH=1 set — committed locally but did NOT push. (Sheet rows will NOT be flipped to merged either, since we don't want to mark merged on something that hasn't shipped yet.)"
    rm -f /tmp/glossary-sync-plan.txt /tmp/glossary-sync-merged-rows.txt
    exit 0
  fi

  branch="${AUTO_SYNC_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
  say "pushing to origin/$branch"
  git push origin "$branch"
fi

# --- 5. delete handled rows from the Sheet ---------------------------------
# Now that the public CSVs are live (or were already in sync for DUP-only
# runs), remove the just-handled Sheet rows so they don't show up in the
# review queue again. Failure here is non-fatal — the worst case is the
# reviewer sees the same rows next run and they re-no-op (DUP).
if [[ -f /tmp/glossary-sync-merged-rows.txt ]]; then
  say "step 5/5 — removing handled rows from Sheet"
  if "$PYTHON" scripts/mark_merged.py; then
    :
  else
    warn "mark_merged.py failed. The public CSVs are pushed and live, but the Sheet rows are still in place."
    warn "Either fix the Sheet's share permission (Editor for the SA), or delete those rows by hand."
  fi
fi

ok "done. GitHub Pages will redeploy in ~1 minute."
rm -f /tmp/glossary-sync-plan.txt
