# GitLab Migrate Repos

This project helps you migrate between GitLab instances or versions using GitLab's project export/import functionality.

It is based on a Bash script that interacts with a private GitLab instance via the GitLab API.  
The script exports repositories to the following structure:

```
./export/$group-id/$repo-name.tar.gz
```

## Features

- Automatically fetches all GitLab groups and their projects (including subgroups)
- Triggers project exports and waits until they are ready
- Downloads exported `.tar.gz` files to a local folder structure
- Logs all actions to `export.log`

## Prerequisites

Make sure the following tools are installed:

- `bash`
- `curl`
- [`jq`](https://stedolan.github.io/jq/)

## Configuration

Before running the script, set the following variables:

```bash
GITLAB_URL="<gitlab-url>"             # Your GitLab instance URL (e.g. https://gitlab.example.com)
PRIVATE_TOKEN="your-access-token"     # GitLab personal access token with API access
```

You can also export the token before running the script:

```bash
export PRIVATE_TOKEN=your-access-token
```

⚠️ Important: Check GitLab Import/Export Rate Limits
Before running the script, ensure that the Import and Export rate limits in your GitLab instance are properly configured.

Navigate to:
Admin Area > Settings > Network > Import and export rate limits

By default, GitLab allows only 6 export/import operations per minute, which may cause the script to hit rate limits if you're exporting many repositories.

Consider increasing these values temporarily during large migrations.

## Usage
Simply run:

```bash 
bash migrate2.sh
```

The script will:

Fetch all groups via the GitLab API

Export all projects found in those groups

Wait for each export to finish (with a timeout of 30 minutes per project)

Download the resulting archive to exports/<group-path>/<repo>.tar.gz

## Example Output

```java
exports/
├── mygroup
│   ├── project1.tar.gz
│   └── project2.tar.gz
└── anothergroup
    └── subproject.tar.gz
```

## Logging
All actions are logged to export.log.

## Notes
Make sure your GitLab token has sufficient permissions (at least read_api and read_repository)

This script does not perform imports — only exports and downloads

Projects with large repositories may take time to export; the script waits and retries until the export is complete or times out
