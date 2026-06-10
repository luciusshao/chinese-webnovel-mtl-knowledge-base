# Glossary Maintainer Script

Only one maintainer script remains: `scripts/auto_sync.sh`.

It does the whole job in one run:

1. pull the Google Sheet;
2. merge `approved` / `replace` rows into `docs/downloads/*.csv`;
3. commit the changed glossary CSV files;
4. push the current branch;
5. delete the handled rows from the Google Sheet.

If the Sheet still contains a conflict, the script aborts before writing,
committing, pushing, or deleting anything.

## Setup

1. Copy the template.

   ```bash
   cp scripts/.env.example scripts/.env
   ```

2. Put your Google service-account JSON in the local work directory.

   ```bash
   mkdir -p ~/.config/glossary-sync
   mv /path/to/caip-493912-64e21cf5c525.json ~/.config/glossary-sync/service-account.json
   chmod 600 ~/.config/glossary-sync/service-account.json
   ```

3. Edit `scripts/.env`.

   ```dotenv
   LOCAL_WORK_DIR=~/.config/glossary-sync
   SHEET_ID=<your-google-sheet-id>
   SHEET_TAB=Form Responses 1
   GOOGLE_SERVICE_ACCOUNT_JSON=${LOCAL_WORK_DIR}/service-account.json
   ```

4. Install dependencies.

   ```bash
   python3 -m venv scripts/.venv
   scripts/.venv/bin/pip install -r scripts/requirements.txt
   ```

## Run

Normal run:

```bash
./scripts/auto_sync.sh
```

Plan only. It still refreshes the local Sheet snapshot, but it will not write
`docs/downloads/*.csv`, commit, push, or delete Sheet rows:

```bash
./scripts/auto_sync.sh --dry-run
```

## Notes

- The script writes the pulled Sheet snapshot to `~/.config/glossary-sync/submissions.csv`.
- Only glossary CSV files under `docs/downloads/*.csv` are committed.
- The script deletes handled rows from the Google Sheet only after `git push` succeeds.
- `scripts/inbox/submissions.example.csv` remains only as a schema example.
