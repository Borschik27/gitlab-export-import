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

## Output

All exported repositories will be saved under:

```text
./$EXPORT_DIR/<group-path>/<project-name>.tar.gz
```

## Logging

You can monitor the progress in real time via:

```bash
tail -f export.log
```

Format:

```java
[2025-05-30 16:47:34] ────────────────────────────────────────────────────────────
[2025-05-30 16:47:34] ➡️ Project export <group>/<repo-name> (ID X)
[2025-05-30 16:47:34] ⏳ Waiting for export: $EXPORT_DIR/<group>/<repo-name> ...
[2025-05-30 16:47:35] ⌛ <repo-name>: waiting for export 0с...
[2025-05-30 16:47:40] 📦 Download: $EXPORT_DIR/<group>/<repo-name>.tar.gz
[2025-05-30 16:47:40] ✅ Export completed: $EXPORT_DIR/<group>/<repo-name>.tar.gz
```

All actions, including wait states and errors, are logged in export.log.

## Notes

- Make sure your GitLab token has sufficient permissions (read_api, read_repository).

- This script performs exports only, not imports.

- Projects with large repositories may take time to export.

- The script uses an internal counter and rate control to avoid hitting GitLab API rate limits.
