# GitLab Export/Import Automation

This repository contains scripts for automated export and import of GitLab projects and their members, including both group and personal namespaces.  
The scripts support incremental export/import, handle nested groups, and preserve project members.

---

## Features

- **Export all projects** from all groups (including subgroups) and all personal namespaces.
- **Export project members** for each project (group and personal).
- **Import projects** into GitLab, preserving group structure and skipping up-to-date projects.
- **Import project members** for each project, matching users by username.
- **Incremental logic:**
  - Skips export/import if the archive is up-to-date with the project.
  - Overwrites only if the archive is newer.
- **Handles personal namespaces:**
  - If a project cannot be imported into a personal namespace, it is placed in a `*-transfer` group.
  - If a project already exists in the personal namespace and is up-to-date, import is skipped.
- **Logging:**
  - All actions and errors are logged to log files.
- **Rate limiting:**
  - Export script respects GitLab API rate limits.

---

## Requirements

- `bash`
- `curl`
- `jq`
- GitLab API access token with sufficient permissions (read/write on all projects and groups)

---

## Environment Variables

You can set these variables before running scripts, or edit them in the scripts:

- `GITLAB_URL` — URL of your GitLab instance (e.g. `https://gitlab.example.com`)
- `PRIVATE_TOKEN` — GitLab personal access token
- `EXPORT_DIR` — Directory for exported archives (default: `exports`)
- `IMPORT_DIR` — Directory for import archives (default: `exports`)
- `MEMBERS_DIR` — Directory for exported/imported members (default: `members`)

---

## Usage

### 1. Export all projects and members

```bash
# Export all projects (group and personal) to exports/
./export.sh
```

- Archives will be saved as `exports/<namespace>/<project>.tar.gz`

```bash
# Export all project members to members/
./export-members.sh
```

- Members will be saved as `members/<normalized_project_path>.members.json`

---

### 2. Import all projects and members

```bash
# Import all projects from exports/
./import.sh
```

- Projects will be imported into the corresponding groups/namespaces.
- If a project is up-to-date, it will be skipped.
- If a project exists and the archive is newer, it will be overwritten.

```bash
# Import all project members from members/
./import-members.sh
```

- Members will be added to the corresponding projects.
- Owners are skipped.
- If a user is not found in GitLab, the member is skipped.

---

### 3. Import/export a single project

```bash
# Export a single project by ID (see export.sh for details)
# Not directly supported, but you can adapt the script.

# Import a single archive
./import.sh exports/group/project.tar.gz
```

---

## How it works

### Export

- **export.sh**

  - Iterates over all groups and users, exporting each project as a `.tar.gz` archive.
  - Skips export if the archive is up-to-date.
  - Handles API rate limits and retries.
  - Logs all actions to `export.log`.

- **export-members.sh**
  - For each project, exports the list of members to a JSON file.
  - Handles both group and personal projects.
  - Logs all actions to `export_members.log`.

### Import

- **import.sh**

  - For each archive, determines the target group/namespace.
  - Creates groups/subgroups as needed.
  - Checks if the project exists and is up-to-date.
  - If the project is up-to-date, skips import.
  - If the archive is newer, overwrites the project.
  - Handles personal namespaces and `*-transfer` logic.
  - Logs all actions to `import.log`.

- **import-members.sh**
  - For each members JSON file, finds the corresponding project.
  - Adds members by username and access level.
  - Skips owners and users not found in GitLab.
  - Logs all actions to `import_members.log`.

---

### Subsequence

1. Add or import personal exporting environment variables to `export.sh` and `export-members.sh`.

2. Start exporting projects and members.

3. Check the `exports/` and `members/` directories for exported archives and member files.

4. Check the `export.log` and `export_members.log` for details on exported projects and members.

5. Add or import personal exporting environment variables to `import.sh` and members using `import-members.sh`.

6. Start importing projects and members.

7. Check the `import.log` and `import_members.log` for details on imported projects and members.

---

## Notes

- **Personal namespaces:**  
  If a project cannot be imported directly into a user's namespace (API limitation), it is imported into a `<username>-transfer` group.  
  You should move it manually after import if needed.

- **Incremental import/export:**  
  The scripts compare project last activity date and archive modification time to avoid unnecessary operations.

- **Members import:**  
  Only users existing in the target GitLab will be added as members. Owners are skipped.

- **Error handling:**  
  All errors and skipped items are logged.  
  After export, a list of projects that timed out is shown with manual export instructions.

- **Normalization:**  
  Project and group paths are normalized to be GitLab-compatible (lowercase, no spaces, etc.), but display names are preserved.

---

## Logging

- All actions are logged to `export.log`, `export_members.log`, `import.log`, and `import_members.log`.
- Errors and skipped items are logged with details for troubleshooting.
- You can check these logs to understand what was exported/imported and if any issues occurred.

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

---

## Example: Count all exported archives

```bash
find exports/ -type f -name '*.tar.gz' | wc -l
```

---

## Troubleshooting

- **API errors:**  
  Check your `PRIVATE_TOKEN` and `GITLAB_URL`.
- **jq/curl not found:**  
  Install them via your package manager (`sudo apt install jq curl`).
- **Permission denied:**  
  Make sure you have write permissions to the export/import directories.
