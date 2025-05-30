#!/bin/bash

set -e

LOG_FILE="export.log"
MAX_WAIT_SECONDS=180 # 3 minuts
MAX_EXPORTS_PER_MINUTE=6

# GitLab URL, Token, Export Dir
GITLAB_URL="${GITLAB_URL:-your-gitlab-url}"
PRIVATE_TOKEN="${PRIVATE_TOKEN:-your-access-token}"
EXPORT_DIR="${EXPORT_DIR:-exports}"

export_count=0
start_time=$(date +%s)

# Checking dependencies
command -v jq >/dev/null 2>&1 || { echo >&2 "❌ jq is not installed. Install jq."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "❌ curl is not installed. Install curl."; exit 1; }

log() {
  local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

check_export_rate_limit() {
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))

  if (( export_count >= MAX_EXPORTS_PER_MINUTE )); then
    if (( elapsed < 60 )); then
      log "⏱ Limit reached $MAX_EXPORTS_PER_MINUTE exports/min. Pause $((60 - elapsed + 10)) sec..."
      sleep $((60 - elapsed + 10))
    fi
    export_count=0
    start_time=$(date +%s)
  fi
}

export_project() {
  local project_id=$1

  check_export_rate_limit
  curl --request POST \
    --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
    "$GITLAB_URL/api/v4/projects/$project_id/export" > /dev/null
  export_count=$((export_count + 1))
}

download_export() {
  local project_id=$1
  local name=$2
  local path=$3

  log "⏳ Waiting for export: $EXPORT_DIR/$path/$name ..."
  local seconds=0

  while true; do
    export_status=$(curl --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
      "$GITLAB_URL/api/v4/projects/$project_id/export" | jq -r .export_status)

    if [ "$export_status" == "finished" ]; then
      mkdir -p "$EXPORT_DIR/$path"
      log "📦 Download: $EXPORT_DIR/$path/$name.tar.gz"
      curl --progress-bar --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$project_id/export/download" \
        --output "$EXPORT_DIR/$path/$name.tar.gz"
      log "✅ Export completed: $EXPORT_DIR/$path/$name.tar.gz"
      log ""
      break
    elif [ "$export_status" == "failed" ]; then
      log "❌ Export error: $name"
      break
    elif (( seconds >= MAX_WAIT_SECONDS )); then
      log "⏱ Export timeout ($MAX_WAIT_SECONDS sec): $name. Skipping..."
      break
    else
      if (( seconds % 30 == 0 )); then
        log "⌛ $name: waiting for export ${seconds}с..."
      fi
      sleep 5
      seconds=$((seconds + 5))
    fi
  done
}

# Getting all groups taking into account subgroups and pagination
group_ids=()
page=1
while :; do
  response=$(curl --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
    "$GITLAB_URL/api/v4/groups?all_available=true&per_page=100&page=$page")
  count=$(echo "$response" | jq 'length')
  if [ "$count" -eq 0 ]; then break; fi

  ids=$(echo "$response" | jq -r '.[].id')
  group_ids+=($ids)
  page=$((page + 1))
done

# Processing each group
for GROUP_ID in "${group_ids[@]}"; do
  log "📁 Group Processing ID: $GROUP_ID"

  page=1
  while :; do
    projects=$(curl --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
      "$GITLAB_URL/api/v4/groups/$GROUP_ID/projects?include_subgroups=true&per_page=100&page=$page")

    count=$(echo "$projects" | jq 'length')
    if [ "$count" -eq 0 ]; then break; fi

    echo "$projects" | jq -c '.[]' | while read -r project; do
      id=$(echo "$project" | jq -r .id)
      name=$(echo "$project" | jq -r .name)
      path_with_namespace=$(echo "$project" | jq -r .path_with_namespace)
      namespace_path=$(dirname "$path_with_namespace")

      log "────────────────────────────────────────────────────────────"
      log "➡️ Project export $path_with_namespace (ID $id)"
      export_project "$id"
      download_export "$id" "$name" "$namespace_path"
    done

    page=$((page + 1))
  done
done

