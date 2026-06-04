# Maintainer Workflow — Glossary Submission Review

> **Internal SOP. Not published to the public site.**
> This document lives at the repository root so it does **not** get rendered by Jekyll.
> If you ever move it into `docs/`, add `sitemap: false` to its front matter
> and make sure it is **not** linked from `docs/navigation.md`.

---

## TL;DR — your routine in 2 steps (with auto_sync.sh)

After the one-time setup in §0 and §3.0, every batch is just:

```
┌────────────────────────────────────────────────────────────────┐
│  0. (Already running)  User submits via /contribute → row      │
│                        lands in your Google Sheet.             │
├────────────────────────────────────────────────────────────────┤
│  1. REVIEW                                                     │
│     Open the response sheet. For each new row, set `status`:   │
│        approved | merged | rejected | dup | pending            │
│     (See §2 for the rules. `pending` = "I'll come back.")      │
├────────────────────────────────────────────────────────────────┤
│  2. ONE-LINER                                                  │
│     cd <repo> && ./scripts/auto_sync.sh                        │
│     · pulls Sheet → submissions.csv                            │
│     · runs sync.py dry-run, aborts if any CLASH                │
│     · sync.py --apply (auto-backups *.bak.<ts>)                │
│     · git add docs/downloads/*.csv && git commit && git push   │
├────────────────────────────────────────────────────────────────┤
│  3. CLOSE THE LOOP (back in Sheet)                             │
│     Flip just-pushed rows from `approved` → `merged` so they   │
│     are not reprocessed next run.                              │
└────────────────────────────────────────────────────────────────┘
```

**Volume rule of thumb**: do steps 1-3 in one sitting once a week. The shell
step is ~10 seconds; the review is the only thing that takes time.

**If `auto_sync.sh` reports a CLASH**, it stops *before* commit. Resolve in the
Sheet (set `status=rejected`, or edit `preferred_english` directly in the CSV)
then re-run. See §2.3 for the decision matrix.

> Want the manual flow instead? §3.2 keeps it documented (export CSV, run
> `sync.py` by hand, git by hand). Use it if Python or the SA key is unavailable.

---

## 0. One-time setup

Run these once when the form is first wired up. They take ~10 minutes total.

### 0.1 Bind a response sheet

1. Open the Google Form: <https://forms.google.com> → "Chinese Webnovel MTL Glossary Submission"
2. Click the **Responses** tab.
3. Click the green Sheets icon → "Create a new spreadsheet" → name it `glossary-submissions`.
4. Open the sheet. Each new submission now lands here automatically.

### 0.2 Add review columns

In the sheet, append four columns to the right of the form-generated columns:

| Column        | Values                                                 | Purpose                                        |
| ------------- | ------------------------------------------------------ | ---------------------------------------------- |
| `status`      | `pending` / `approved` / `rejected` / `merged` / `dup` | Review state                                   |
| `reviewer`    | your initials                                          | Who reviewed it                                |
| `reviewed_at` | YYYY-MM-DD                                             | Date of review                                 |
| `notes`       | free text                                              | Why approved/rejected, conflict resolution     |

> Tip: lock the form-generated columns by right-clicking the header → "Protect range".

### 0.3 Email notifications

Form → ⋮ menu → "Get email notifications for new responses". Daily check is fine.

### 0.4 Wire up the contribute page (entry IDs)

The on-site form at `/contribute` submits each row directly to the Google Form's
`formResponse` endpoint. To do that, the site needs to know the numeric `entry.XXX`
ID of each form field. Steps:

1. Open the Google Form **editor**.
2. Click the ⋮ menu (top-right of the editor) → **"Get pre-filled link"**.
3. In the prefill view, fill each field with a recognisable placeholder:
   - Genre → `GENRE_X`
   - Chinese term → `CHINESE_X`
   - Preferred English → `EN_X`
   - Reason / context → `REASON_X`
   - (other fields can be left blank)
4. Click **"Get link"** at the bottom and copy the URL. It looks like:

   ```
   https://docs.google.com/forms/d/e/<formId>/viewform?usp=pp_url
     &entry.111111=GENRE_X
     &entry.222222=CHINESE_X
     &entry.333333=EN_X
     &entry.444444=REASON_X
   ```

5. Open `docs/_config.yml` and fill in:

   ```yaml
   google_form_action_url:    "https://docs.google.com/forms/d/e/<formId>/formResponse"
   entry_genre:               "entry.111111"
   entry_chinese:             "entry.222222"
   entry_preferred_english:   "entry.333333"
   entry_reason:              "entry.444444"
   ```

   > Note: change `viewform` to `formResponse` in the action URL — that is the
   > endpoint that accepts POST submissions.

6. Commit, push. The contribute page is now live with invisible Google Form backend.
   If any entry ID is empty, the page automatically falls back to a
   "copy-to-clipboard + email maintainer" mode, so the site never breaks.

### 0.5 Form field shape (current)

The on-site form sends only **four** fields:

| On-site label       | Maps to Google Form field    | Required |
| ------------------- | ---------------------------- | -------- |
| Genre               | Genre / 体裁                 | yes      |
| Chinese term        | Chinese term / 中文术语      | yes      |
| Preferred English   | Preferred English / 推荐英文 | yes      |
| Reason (optional)   | Reason or context / 理由     | no       |

Older fields in the Google Form (`Alternative English`, `Source novel`, `Your contact`)
remain in the form schema but are **left blank by the site** and **ignored by `sync.py`**.
You can either delete them from the form for tidiness, or keep them in case you ever
re-enable manual submissions through the live form URL.

---

## 1. Data flow at a glance

```
   user fills /contribute table  (on-site UI)
              │
              │ JS POSTs each row separately
              ▼
   Google Form `formResponse` endpoint
              │
              ▼
   Google Sheet (glossary-submissions)
              │
              ▼
       you review (this doc)
              │
       ┌──────┼──────┐
       ▼      ▼      ▼
   approved  merged  rejected
       │      │
       ▼      ▼
   append to       update `notes`
   docs/downloads  in existing row
   /<genre>.csv
              │
              ▼
       git commit + push
              │
              ▼
    GitHub Pages rebuilds
    /glossary-browser updates
    /glossary-library updates
```

> Each on-site row → one row in the Google Sheet. A user submitting 5 terms
> creates 5 sheet rows with the same timestamp (within a second of each other).

---

## 2. Review SOP — per submission

Decide which of the five statuses applies. **Use status `pending` only as the default for a row you have not looked at yet.**

### 2.1 `dup` — exact duplicate

The submission matches an existing row on **both** `chinese` and `preferred_english`.

- Set `status = dup`. No file change. Done.

### 2.2 `merged` — note enrichment

The submission's `chinese` already exists, but it brings useful new context in
the `reason` field worth preserving.

- Open the corresponding `docs/downloads/<genre>-core-terms.csv`.
- Find the existing row.
- Append or rewrite the `notes` column to incorporate the user's reasoning
  (keep it short — one line).
- Set `status = merged` in the sheet.

### 2.3 Conflict — same Chinese, different recommended English

The hardest case. Decide which English form should be the recommended one.

| Sub-case                            | Recommended action                                                                               |
| ----------------------------------- | ------------------------------------------------------------------------------------------------ |
| New form is clearly better          | Update `preferred_english` in the CSV. Set `status = approved`. Mention old form in `notes` if useful (e.g. `notes: "was: ascension; transcendence reads cleaner"`). |
| Existing form is better             | Set `status = rejected` with a one-line reason. No CSV change.                                   |
| Unclear / both common               | Keep existing as `preferred_english`. Set `status = rejected` with a one-line reason.            |
| The submission is genre-mislabeled  | Move it to the correct CSV, then apply the rule above.                                           |

Always add a one-line `notes` entry when overriding the existing recommendation.

### 2.4 `approved` — fresh entry

The `chinese` term is not in any CSV. Append the row to
`docs/downloads/<genre>-core-terms.csv`.

- Make sure `genre` matches the file you are appending to.
- The submitted `reason` becomes the CSV's `notes` column.

### 2.5 `rejected`

Reasons that justify a rejection:

- copyrighted chapter content;
- one-off character names from a single novel that have no broader value;
- unsafe / off-policy content;
- submitter clearly trolling.

Set `status = rejected` and a brief `notes`. Never delete from the sheet —
keeping the trail helps spot patterns of abuse later.

### 2.6 `pending` — defer

If you don't have time, leave it as `pending` and move on. There is no SLA.

---

## 3. Syncing approved rows to the repo

You have **three paths**, in order of recommendation:

- **§3.0 — `auto_sync.sh`** (one-liner, recommended). Fully automates Sheet
  pull → conflict-check → CSV write → git commit → git push.
- **§3.1 — `sync.py` only** (semi-manual fallback). Use when the Service Account
  flow is broken or you want to inspect the diff before pushing yourself.
- **§3.2 — pure manual** (last resort). Edit the CSV by hand.

### 3.0 Path A — `auto_sync.sh` (recommended)

#### One-time setup (~15 min, do this once)

1. **Create a Google Cloud Service Account**

   - Open <https://console.cloud.google.com>, create or pick a project.
   - APIs & Services → Library → enable **Google Sheets API**.
   - APIs & Services → Credentials → Create credentials → **Service account**.
     - Name: `glossary-sync`. No roles needed. Skip "grant users access".
   - On the new SA's page → **Keys** tab → Add key → Create new key → **JSON**.
   - The browser downloads a `*.json` file. Move it to a private spot:
     ```bash
     mkdir -p ~/.config/glossary-sync
     mv ~/Downloads/<project>-*.json ~/.config/glossary-sync/service-account.json
     chmod 600 ~/.config/glossary-sync/service-account.json
     ```
   - Open the JSON and note the `client_email` field — looks like
     `glossary-sync@<project>.iam.gserviceaccount.com`.

2. **Share the Sheet with the SA**

   - Open the `glossary-submissions` Google Sheet.
   - Click **Share** (top-right) → paste the `client_email` → permission
     **Viewer** is enough → uncheck "Notify people" → Send.

3. **Configure the repo's local `.env`**

   ```bash
   cp scripts/.env.example scripts/.env
   $EDITOR scripts/.env
   # Fill in:
   #   SHEET_ID=<the long id from the Sheet's URL>
   #   SHEET_TAB=Form Responses 1     (default; change if you renamed)
   #   SA_KEY_PATH=~/.config/glossary-sync/service-account.json
   ```

   `scripts/.env` is gitignored. Never commit it.

4. **Install Python deps in a venv**

   ```bash
   python3 -m venv scripts/.venv
   scripts/.venv/bin/pip install -r scripts/requirements.txt
   ```

   The venv is also gitignored.

5. **Smoke test (read-only)**

   ```bash
   scripts/.venv/bin/python scripts/pull_sheet.py
   # → ✓ pulled N row(s) from 'Form Responses 1' → scripts/inbox/submissions.csv
   ```

   If you see a 403 / "permission denied" error, double-check step 2.

#### Per-batch workflow

```bash
# 1. In the Google Sheet: review new rows, mark each row's `status`:
#    approved | rejected | dup | merged | pending  (see §2)

# 2. From the repo root, run the one-liner:
./scripts/auto_sync.sh
```

That's it. The script will:

1. Refuse to run if the working tree has unrelated dirty files (safety).
2. `pull_sheet.py` → fresh `scripts/inbox/submissions.csv`.
3. `sync.py` dry-run. If any **CLASH**, prints them and aborts.
4. `sync.py --apply` (with auto-backups `docs/downloads/*.bak.<timestamp>`).
5. `git add docs/downloads/*.csv && git commit -m "glossary: add N terms…"`.
6. `git push` to the current branch.

GitHub Pages redeploys within ~1 minute. Then go back to the Sheet and flip
the just-pushed rows from `approved` → `merged` so the next run skips them.

#### When the script stops short

| Scenario              | What happens                                  | What to do                                                       |
| --------------------- | --------------------------------------------- | ---------------------------------------------------------------- |
| Working tree dirty    | Aborts before pulling Sheet                   | Commit/stash unrelated changes, re-run                           |
| Sheet auth fails      | Aborts at step 1 with the API error           | Check `scripts/.env`; verify SA shared on Sheet                  |
| `CLASH` in dry-run    | Aborts before commit; prints the conflicts    | Resolve in Sheet (see §2.3) and re-run                           |
| Nothing to merge      | Exits cleanly (`nothing new to merge`)        | Nothing                                                          |
| Empty diff after sync | Skips the commit (no empty commits ever)      | Nothing                                                          |
| Push rejected         | Commit succeeded locally; push errored        | `git pull --rebase && git push`                                  |

#### Trial mode

Want to check what the script *would* do without pushing? Set `SKIP_PUSH=1`:

```bash
SKIP_PUSH=1 ./scripts/auto_sync.sh
# Pulls, syncs, commits locally; does NOT push. Inspect with `git log -1 --stat`.
# When happy: `git push`. When unhappy: `git reset --hard HEAD~1`.
```

### 3.1 Path B — `scripts/sync.py` (semi-manual)

Zero-dependency Python 3 script. It reads a Google Sheet CSV export, picks
only `status=approved` rows, routes them to the right `docs/downloads/<genre>-core-terms.csv`,
and **refuses to overwrite conflicts**.

#### One-time

The script lives at `scripts/sync.py`. Nothing to install.

#### Per-batch workflow

```bash
# 1. Export the response sheet:
#    Google Sheet → File → Download → Comma-separated values (.csv)
#    Save to:  scripts/inbox/submissions.csv
#    (This file is gitignored — it stays on your laptop.)

# 2. Dry-run first to see the plan
python3 scripts/sync.py
#   - lists every approved row as ADD / DUP / CLASH
#   - shows per-file additions
#   - exits without touching disk

# 3. If the plan looks right, apply
python3 scripts/sync.py --apply
#   - backs up each modified CSV (docs/downloads/*.bak.<timestamp>)
#   - appends approved rows in the canonical column order
#   - prints next-step git commands

# 4. Inspect, preview, commit
git diff docs/downloads/
docker restart jekyll-preview          # optional: see at http://localhost:4000
git add docs/downloads/*.csv
git commit -m "glossary: add N terms from submissions"
git push

# 5. Back in the Google Sheet, mark the rows you just merged:
#    status=merged for ADDs, status=dup for DUPs, status remains 'approved'
#    (or move to 'pending') for CLASHes you still need to think about.
```

#### What the script handles for you

| Sheet row              | Outcome in CSV                                  |
| ---------------------- | ----------------------------------------------- |
| `status=approved`, fresh chinese | Appended to `<genre>-core-terms.csv`  |
| `status=approved`, exact same chinese + same English  | Skipped (logged as DUP)        |
| `status=approved`, same chinese but different English | **Refused** — listed as CLASH, you fix manually |
| `status=approved`, missing chinese / English          | Skipped, logged as INVALID    |
| `status=approved`, genre is not xianxia/wuxia/xiuxian | Skipped (warning)             |
| `status=pending` / `rejected` / `merged` / blank      | Ignored                       |

#### Conflicts (`CLASH`)

The script never overwrites. If it reports a conflict, your options:

1. Open the existing CSV row, decide whether to:
   - **keep existing as preferred**, fold the user's reasoning into the existing `notes` cell, then in the sheet set `status=merged`;
   - **promote new English to preferred**, edit `preferred_english` directly (mention the old form in `notes` if useful), then re-run `sync.py`;
   - **reject the submission**, set `status=rejected` in the sheet.

#### Custom genres

If a row's `genre` is something we don't ship a CSV for (e.g. `other`), the
script warns and skips. To temporarily allow it:

```bash
python3 scripts/sync.py --apply --include-genre other
```

The row will still need a corresponding `docs/downloads/other-core-terms.csv`
on disk, otherwise it will create one.

#### Schema reminder

Expected inbox columns (Google Sheet defaults + the four review columns from §0.2):

| From the form (auto)            | Added by you (§0.2)            |
| ------------------------------- | ------------------------------ |
| `Timestamp`                     | `status`                       |
| `Genre`                         | `reviewer`                     |
| `Chinese term`                  | `reviewed_at`                  |
| `Preferred English`             | `notes`                        |
| `Alternative English`           | (deprecated, ignored by sync.py) |
| `Reason or context`             |                                |
| `Source novel (optional)`       |                                |
| `Your contact (optional)`       |                                |

`scripts/inbox/submissions.example.csv` ships with the repo as a schema template.

### 3.2 Path C — pure manual

For one-off cases or if Python is unavailable:

```bash
# 1. pull latest
git pull --rebase

# 2. open the relevant CSV
$EDITOR docs/downloads/xianxia-core-terms.csv   # or wuxia / xiuxian

# 3. append rows in column order:
#    genre,chinese,preferred_english,notes
#    quote any field that contains a comma or newline.

# 4. commit
git add docs/downloads/*.csv
git commit -m "glossary: add N <genre> terms from submissions"
git push
```

### 3.3 Local preview (optional, applies to all paths)

```bash
docker run --rm -v "$PWD/docs":/srv/jekyll -p 4000:4000 jekyll/jekyll:4 \
  sh -c "bundle install --quiet && jekyll serve --host 0.0.0.0"
# open http://localhost:4000/glossary-browser.html
```

---

## 4. Periodic maintenance

- **Monthly**: skim the sheet for spam patterns; tighten the form description if needed.
- **Quarterly**: review `notes` columns; tighten wording where multiple submissions added overlap.
- **Yearly**: regenerate `starter-combined-glossary.csv` from the three genre files (it's a curated highlight reel, not a sum).

---

## 5. Escalation

- Suspect abuse / coordinated spam → temporarily disable the form ("Accepting responses" toggle in the Form's Responses tab). The contribute page will then fall back to the email path automatically (Google returns an error and JS shows a fallback toast).
- Site is down on GitHub Pages → check the Actions tab; usually a CSV with an
  unescaped quote breaking Jekyll. Revert the offending commit, fix the CSV, redeploy.
- Lost access to the Google account → the form action URL and entry IDs are in
  `docs/_config.yml`. Replace with a new form's values, push, the site updates within a minute.

---

## 6. FAQ

**Q. The contribute page shows "Form backend not configured yet — Submit will fall back to email." What's wrong?**
At least one of `entry_genre`, `entry_chinese`, `entry_preferred_english` in
`docs/_config.yml` is still empty. Re-run §0.4 to capture the IDs, fill them
in, push.

**Q. How do I notify the submitter their term was published?**
You don't — submissions are anonymous by default. The on-site form does not
ask for an email.

**Q. Can I run a script to sync `approved` rows automatically?**
Yes — see §3.0 (`scripts/auto_sync.sh`) for the recommended one-liner that
pulls the Sheet, runs `sync.py`, commits and pushes. §3.1 covers the
semi-manual `sync.py`-only fallback.
For a fully unattended sync (cron / GitHub Action), defer until volume
justifies it (>20 submissions/week).

**Q. What if a submission is in traditional Chinese?**
Convert to simplified before storing in CSV (project default). Mention the
traditional form in `notes` if you think it helps readers (e.g. `notes: "trad: 飛升"`).

**Q. How do I test that the wiring works without spamming the live sheet?**
Submit one obvious test row from the page (e.g. `chinese=测试 preferred_english=test`),
verify it appears in the response sheet, then delete that row.

---

_Last updated: 2026-06-04. Update this date when the SOP changes._
