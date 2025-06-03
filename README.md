# GitLab Migrate Repos

This project helps you migrate repositories between GitLab instances or versions using the GitLab project export/import API.
For example, if you need to migrate from version 8.9.x to 14.x.x or oth. You have few projects and gradual migration is long.

It is based on a Bash script that connects to a private GitLab instance via the API and exports repositories into the custom local directory directory.

## Features

- Automatically detects all groups and subgroups.
- Exports all repositories within those groups.

- Tracks the export status and waits until it's ready for download.

- Handles GitLab rate limits for export/import requests.

- Logs actions with timestamps into export.log.

- Respects user-defined export rate limits to avoid GitLab throttling.

- Automatically skips already exported and unchanged repositories (checks last_activity_at vs archive date).
- If export status is "none" or "null", the script will initiate export even if archive exists (but only if the project was updated or archive is missing).
- If export fails, the script retries up to 3 times before skipping the project.
- Handles export timeouts and provides manual API commands for retrying failed exports.

## Usage

1. Make sure you have jq and curl installed:

   ```bash
   sudo apt install jq curl
   ```

2. Open export.sh and replace url, token, data dir, or set your GitLab instance URL, private token and custom dir:

   ```bash
   export PRIVATE_TOKEN=your-access-token
   export GITLAB_URL="https://gitlab.example.com"
   export EXPORT_DIR=your-local-dir
   ```

3. Run the script:

   ```bash
   bash export.sh
   ```

## GitLab Export/Import Rate Limits

Important: Before running the script, make sure to check the export/import rate limits in GitLab:

- Navigate to: `Admin Area > Settings > Network > Import and export rate limits`

By default, GitLab allows no more than 6 export/import requests per minute.

This script respects that limit by pausing if the limit is reached (waiting roughly until a minute passes before continuing).

You can configure the limit with the MAX_EXPORTS_PER_MINUTE variable inside the script (default: 6)

## Configuration

Before running the script, set the following variables:

```text
GITLAB_URL="<gitlab-url>"             # Your GitLab instance URL (e.g. https://gitlab.example.com)
PRIVATE_TOKEN="your-access-token"     # GitLab personal access token with API access
EXPORT_DIR="${EXPORT_DIR:-exports}"   # Local data directory for exporting projects
```

You can also export the token before running the script:

```text
export PRIVATE_TOKEN=your-access-token
export GITLAB_URL="https://gitlab.example.com"
export EXPORT_DIR=your-local-dir
```

## How it works

- For each project, the script checks if an archive already exists and compares its modification date with the project's last_activity_at from GitLab.
- If the project hasn't changed since the last export, it is skipped (no redundant downloads).
- If the export status is "none" or "null" (never exported or status unknown), the script will initiate export only if the project was updated or archive is missing.
- If export fails (status "failed"), the script retries up to 3 times.
- If export takes too long (timeout), the project is skipped and a manual API command is provided in the log for retrying.

## Output

All exported repositories will be saved under:

```text
./$EXPORT_DIR/<group-path>/<project-name>.tar.gz
```

If a project export times out, you will see a list of such projects at the end of the log with ready-to-use API commands for manual export:

```text
List of repositories skipped due to export timeout:
- <group>/<project> (ID: <id>)
  Manual export via API:
    curl --request POST --header 'PRIVATE-TOKEN: ...' '.../api/v4/projects/<id>/export'
    curl --header 'PRIVATE-TOKEN: ...' '.../api/v4/projects/<id>/export' | jq .export_status
    curl --progress-bar --header 'PRIVATE-TOKEN: ...' '.../api/v4/projects/<id>/export/download' --output '...tar.gz'
```

## Logging

You can monitor the progress in real time via:

```bash
tail -f export.log
```

Format:

```text
[YYYY-MM-DD HH:MM:SS] ...
[YYYY-MM-DD HH:MM:SS] ➡️ Project export <group>/<repo-name> (ID X)
[YYYY-MM-DD HH:MM:SS] ⏳ Waiting for export: $EXPORT_DIR/<group>/<repo-name> ...
[YYYY-MM-DD HH:MM:SS] ⌛ <repo-name>: waiting for export 0s... (status: started)
[YYYY-MM-DD HH:MM:SS] 📦 Download: $EXPORT_DIR/<group>/<repo-name>.tar.gz
[YYYY-MM-DD HH:MM:SS] ✅ Export completed: $EXPORT_DIR/<group>/<repo-name>.tar.gz
[YYYY-MM-DD HH:MM:SS] ⏭  The repository is already retrieved and has not been changed: ...
[YYYY-MM-DD HH:MM:SS] ❌ Export failed for ...
[YYYY-MM-DD HH:MM:SS] ⏱ Export timeout (180 sec): ... Skipping...
```

All actions, including wait states and errors, are logged in export.log. You can also see DEBUG lines with export_status for troubleshooting.

## Notes

- Make sure your GitLab token has sufficient permissions (read_api, read_repository).

- This script performs exports only, not imports.

- Projects with large repositories may take time to export.

- The script uses an internal counter and rate control to avoid hitting GitLab API rate limits.

- The script automatically handles export retries and timeouts, and provides manual API commands for failed exports.
