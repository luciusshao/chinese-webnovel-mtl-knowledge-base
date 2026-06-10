# Maintainer Workflow — Glossary Submission Review

> **Internal SOP. Not published to the public site.**
> This document lives at the repository root so it does **not** get rendered by Jekyll.
> If you ever move it into `docs/`, add `sitemap: false` to its front matter
> and make sure it is **not** linked from `docs/navigation.md`.

---

## TL;DR — your routine in 2 steps (with the one script)

After the one-time setup in §0 and §3.0, every batch is just:

```
┌────────────────────────────────────────────────────────────────┐
│  0. (Already running)  User submits via /contribute → row      │
│                        lands in your Google Sheet.             │
├────────────────────────────────────────────────────────────────┤
│  1. REVIEW                                                     │
│     Open the response sheet. For each new row, set `status`:   │
│        approved | replace | rejected | (pending = skip)        │
│     · approved → publish as a new term                         │
│     · replace  → overwrite the existing English with this one  │
│     · rejected → ignore (junk / not better than existing)      │
│     · pending  → "I'll come back". the script ignores it.      │
│     (See §2 for the full table.)                               │
├────────────────────────────────────────────────────────────────┤
│  2. ONE-LINER                                                  │
│     cd <repo> && scripts/.venv/bin/python scripts/auto_sync.sh │
│     · pulls Sheet → submissions.csv                            │
│     · builds the plan, aborts if any CLASH                     │
│     · writes CSV backups (*.bak.<ts>)                          │
│     · git add docs/downloads/*.csv && git commit && git push   │
├────────────────────────────────────────────────────────────────┤
│  3. AUTO-CLEANUP (handled by the script)                       │
│     the script deletes the just-handled rows from the Sheet    │
│     (ADD / REPLACE / DUP) so the review queue stays clean.     │
│     Rejected / pending / CLASH'd rows are left in place.       │
└────────────────────────────────────────────────────────────────┘
```

**Volume rule of thumb**: do steps 1-3 in one sitting once a week. The shell
step is ~10 seconds; the review is the only thing that takes time.

**If `scripts/auto_sync.sh` reports a CLASH**, it stops *before* commit. Resolve in
the Sheet by either changing the row's `status` from `approved` to `replace`
(adopt the new English) or to `rejected` (keep the existing English) and
re-run. See §2 for the full table.

> There is no longer a multi-script maintainer flow. Use the one script.

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
| `status`      | `approved` / `replace` / `rejected` / `dup` / `pending` / blank | Review state (only `approved` & `replace` cause writes) |
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
remain in the form schema but are **left blank by the site** and **ignored by the sync script**.
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
   approved replace rejected
       │      │
       ▼      ▼
   append to  overwrite existing row
   docs/downloads  and archive old English
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

For each row, set `status` to one of these values. **Only `approved` and
`replace` cause writes to the public CSVs**; everything else is purely an
audit trail.

| `status`   | What the script does                                                               | When to use                                                                                       |
| ---------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `approved` | Append the term to `<genre>-core-terms.csv`. **Refuses to overwrite** any existing chinese (CLASH). | Fresh, useful term. Default verdict for anything you'd publish as-is.                             |
| `replace`  | Like `approved`, but if the chinese already exists with a different English, **overwrite** it; the old English is auto-archived in the row's `notes`. | The submission proposes a clearly better translation than what's currently published. Use sparingly. |
| `rejected` | Ignore. Row stays in the Sheet for the audit trail.                                | Trolling, copyrighted content, off-policy, one-off character names with no reuse value.            |
| `dup`      | Ignore.                                                                            | (Optional shorthand — the script auto-detects exact duplicates anyway.)                           |
| `pending` (or blank) | Ignore.                                                                | Default — you haven't gotten to this row yet. There is no SLA.                                   |

**Key insight**: you do not need to manually check whether a chinese already
exists in the public CSVs. The script does that for you:

- exact duplicate (same chinese + same English) → silently skipped (DUP)
- same chinese + different English + you wrote `approved` → blocked as CLASH;
  you decide later whether to upgrade to `replace` or `rejected`
- same chinese + different English + you wrote `replace` → overwrites the
  existing row; the previous English lands in the new `notes` value as
  `was: <old English>`, with any prior notes preserved as `(prev: ...)`.

So in practice your reviewing flow is just:

1. Read the submitted Chinese + English + Reason.
2. Decide: is this term worth publishing? → `approved`.
3. If you already know the existing English is worse → `replace` instead.
4. If junk → `rejected`. If unsure → leave as `pending`.

That's the whole job. The script will yell at you (CLASH) only when your
verdict requires extra information you can fix in 1 click.

### 2.x Reasons that justify `rejected`

- copyrighted chapter content;
- one-off character names from a single novel that have no broader value;
- unsafe / off-policy content;
- submitter clearly trolling;
- existing English is fine and the submitted alternative isn't clearly better.

Never delete a rejected row from the Sheet — the trail helps spot patterns
of abuse later.

### 2.x Tips on `replace`

When you set `status = replace`, use the `notes` column to capture *why* the
new form wins (one line):

```
status = replace
notes  = more common in cultivation novels
```

After the next sync, the public CSV row becomes:

```
xianxia,洞府,cave abode,more common in cultivation novels; was: cave residence
```

so future readers can see both the chosen English and the previous
recommendation in one place.

---

## 3. Syncing approved rows to the repo

There is now only **one maintainer path**:

- run `./scripts/auto_sync.sh`

The script does the whole job in one run:

1. pull the Google Sheet into `~/.config/glossary-sync/submissions.csv`;
2. build the plan and stop immediately if any `CLASH` exists;
3. write the changed `docs/downloads/*.csv` files, with `*.bak.<timestamp>` backups;
4. commit only the changed glossary CSV files;
5. push the current branch;
6. delete handled rows from the Google Sheet.

Handled rows means `ADD`, `REPLACE`, and `DUP`. Rejected, pending, and clash rows stay in the Sheet.

### 3.0 One-time setup

1. **Create a Google Cloud Service Account**

   - Open <https://console.cloud.google.com>, create or pick a project.
   - APIs & Services → Library → enable **Google Sheets API**.
   - APIs & Services → Credentials → Create credentials → **Service account**.
   - On the service account page → **Keys** → Add key → Create new key → **JSON**.
   - Move the downloaded key to a private local directory:

     ```bash
     mkdir -p ~/.config/glossary-sync
     mv ~/Downloads/<project>-*.json ~/.config/glossary-sync/service-account.json
     chmod 600 ~/.config/glossary-sync/service-account.json
     ```

2. **Share the Google Sheet with the service account**

   - Open the response Sheet.
   - Click **Share**.
   - Add the service account `client_email`.
   - Give it **Editor** permission.

3. **Configure `scripts/.env`**

   ```bash
   cp scripts/.env.example scripts/.env
   $EDITOR scripts/.env
   ```

   Fill in:

   ```dotenv
   LOCAL_WORK_DIR=~/.config/glossary-sync
   SHEET_ID=<the long id from the Sheet URL>
   SHEET_TAB=Form Responses 1
   GOOGLE_SERVICE_ACCOUNT_JSON=${LOCAL_WORK_DIR}/service-account.json
   ```

4. **Install dependencies**

   ```bash
   python3 -m venv scripts/.venv
   scripts/.venv/bin/pip install -r scripts/requirements.txt
   ```

### 3.1 Routine run

```bash
# 1. In the Google Sheet, review rows and set status:
#    approved | replace | rejected | dup | pending

# 2. Run the script:
./scripts/auto_sync.sh
```

### 3.2 Dry-run

```bash
./scripts/auto_sync.sh --dry-run
```

Dry-run still refreshes the local Sheet snapshot, but it will not write glossary CSVs, commit, push, or delete Sheet rows.

### 3.3 What happens on failure

| Scenario         | What happens                                        | What to do |
| ---------------- | --------------------------------------------------- | ---------- |
| Sheet auth fails | Stops before any glossary CSV write                 | Check `scripts/.env`, key path, and Sheet sharing |
| `CLASH` exists   | Stops before write / commit / push / Sheet deletion | Change the row to `replace` or `rejected`, then rerun |
| `git push` fails | Sheet rows are **not** deleted                      | Fix git and rerun the script |
| No CSV change    | No commit is created; handled DUP rows can still be deleted | Nothing |

### 3.4 Local preview (optional)

```bash
docker run --rm -v "$PWD/docs":/srv/jekyll -p 4000:4000 jekyll/jekyll:4   sh -c "bundle install --quiet && jekyll serve --host 0.0.0.0"
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
Yes. Use `./scripts/auto_sync.sh`. It pulls the Sheet, updates the glossary CSVs,
commits, pushes, and then deletes the handled rows from the Sheet.
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
