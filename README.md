# GitLab Migrate Repos

This project helps you migrate repositories between GitLab instances or versions using the GitLab project export/import API.
For example, if you need to migrate from version 8.9.x to 14.x.x or oth. You have few projects and gradual migration is long.

It is based on a Bash script that connects to a private GitLab instance via the API and exports repositories into the custom local directory directory.

## Features

- **export.sh**
  - Exports all projects from all groups (including subgroups).
  - Exports all personal projects for all users.
  - Skips up-to-date archives (checks last_activity_at vs archive date).
  - Handles API rate limits and export timeouts.
  - Retries failed exports up to 3 times.
  - Logs all actions with timestamps to `export.log`.
  - Provides a summary of processed, exported, skipped, and failed projects.

- **import.sh**
  - Imports all exported archives from the `exports/` directory.
  - Automatically creates groups/subgroups as needed.
  - Skips or updates projects based on last activity date.
  - Logs all actions with timestamps to `import.log`.
  - Provides a summary of imported, skipped, and failed projects.

## Requirements

- Bash
- `curl`
- `jq`
- GitLab API access token with sufficient permissions (admin/root recommended for full export/import)


## Usage

1. Make sure you have jq and curl installed:

   ```bash
   sudo apt install jq curl
   ```

2. Export all projects

   ```bash
   export GITLAB_URL="https://gitlab.example.com"
   export PRIVATE_TOKEN="your-access-token"
   ./export.sh
   ```

   - All exported archives will be saved in the `exports/` directory by default.
   - Progress and results are logged to `export.log`.

3. Import all projects

   ```bash
   export GITLAB_URL="https://gitlab.example.com"
   export PRIVATE_TOKEN="your-access-token"
   ./import.sh
   ```

   - All archives from the `exports/` directory will be imported.
   - Progress and results are logged to `import.log`.
   - Also you can import only one project by specifying its path:

   ```bash
   ./import.sh <group-path>/<project-name>
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

Monitor progress in real time:

```bash
tail -f export.log
tail -f import.log
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

- **Personal projects** are imported into a group with the same name as the user (due to GitLab API limitations).
- To move a project to a user's personal namespace, use the GitLab UI ("Transfer project") after import.
- For large GitLab instances, the process may take significant time.
- The scripts respect GitLab export/import rate limits (default: 6 per minute, configurable).
- All actions, including retries and timeouts, are logged with timestamps.
