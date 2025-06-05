#!/bin/bash
# Import projects from the exports/ directory or a single archive into GitLab via projects/import
# Usage:
#   ./import.sh                 # bulk import of all archives from exports/
#   ./import.sh path/to/archive # import only one archive

LOG_FILE="import.log"

# GitLab URL, Token, Import Dir
GITLAB_URL="${GITLAB_URL:-your-gitlab-url}"
PRIVATE_TOKEN="${PRIVATE_TOKEN:-your-access-token}"
IMPORT_DIR="${IMPORT_DIR:-exports}"

FAILED_IMPORTS=()
SKIPPED_UPTODATE=()
REPLACED_PROJECTS=()

# Checking dependencies
command -v jq >/dev/null 2>&1 || {
	echo >&2 "❌ jq is not installed. Install jq."
	exit 1
}

command -v curl >/dev/null 2>&1 || {
	echo >&2 "❌ curl is not installed. Install curl."
	exit 1
}

log() {
	local msg
	msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
	echo "${msg}" | tee -a "${LOG_FILE}"
}

# Function to normalize path/name for GitLab namespace/path
normalize_gitlab_path() {
	# Only latin, digits, -, _, .; spaces and everything else replaced with -
	echo "$1" | iconv -c -t ascii//TRANSLIT | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g; s/^-*//; s/-*$//'
}

# Recursive creation of nested groups
get_or_create_group() {
	local full_path="$1"
	local parent_id=""
	local current_path=""
	IFS='/' read -ra PARTS <<<"$full_path"
	for part in "${PARTS[@]}"; do
		norm_part=$(normalize_gitlab_path "$part")
		if [[ -z $current_path ]]; then
			current_path="$norm_part"
		else
			current_path="$current_path/$norm_part"
		fi
		# Check if such group exists
		resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups/${current_path}")
		group_id=$(echo "$resp" | jq -r .id 2>/dev/null || true)
		if [[ -z $group_id || $group_id == "null" ]]; then
			# Create group
			data="{\"name\": \"$part\", \"path\": \"$norm_part\""
			if [[ -n $parent_id ]]; then
				data=", \"parent_id\": $parent_id$data"
				data="{${data#*, }}"
			else
				data="$data}"
			fi
			create_group_resp=$(curl --silent --request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
				--header "Content-Type: application/json" \
				--data "$data" \
				"${GITLAB_URL}/api/v4/groups")
			group_id=$(echo "$create_group_resp" | jq -r .id 2>/dev/null || true)
			if [[ -z $group_id || $group_id == "null" ]]; then
				log "❌ Failed to create group $current_path: $create_group_resp"
				exit 1
			fi
			log "Group created: $current_path (id: $group_id)"
		else
			log "Group already exists: $current_path (id: $group_id)"
		fi
		parent_id="$group_id"
	done
	echo "$group_id"
}

import_one() {
	ARCHIVE_PATH="$1"
	if [[ -z ${ARCHIVE_PATH} || ! -f ${ARCHIVE_PATH} ]]; then
		log "❌ Specify the path to the .tar.gz archive (e.g., ${IMPORT_DIR}/<proj_id_name>/<proj_name>.tar.gz)"
		exit 1
	fi
	rel_path="${ARCHIVE_PATH#"${IMPORT_DIR}/"}"
	group_path="$(dirname "${rel_path}")"
	project_name="$(basename "${rel_path}" .tar.gz)"

	# Build normalized group path from parts
	IFS='/' read -ra PARTS <<<"${group_path}"
	norm_group_path=""
	for part in "${PARTS[@]}"; do
		norm_part=$(normalize_gitlab_path "$part")
		if [[ -z $norm_group_path ]]; then
			norm_group_path="$norm_part"
		else
			norm_group_path="$norm_group_path/$norm_part"
		fi
	done

	norm_project_name=$(normalize_gitlab_path "${project_name}")

	log "────────────────────────────────────────────────────────────"
	log "➡️ Import: ${group_path}/${project_name}"

	# 1. Recursively create group (and get id)
	group_id=$(get_or_create_group "$group_path")

	# 2. Check for existing project
	get_proj_resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects?search=${norm_project_name}")
	project_id=$(echo "${get_proj_resp}" | jq -r ".[] | select(.path_with_namespace==\"${norm_group_path}/${norm_project_name}\") | .id" | head -n1)
	project_last_activity=$(echo "${get_proj_resp}" | jq -r ".[] | select(.path_with_namespace==\"${norm_group_path}/${norm_project_name}\") | .last_activity_at" | head -n1)
	archive_mtime=$(date -u -d "@$(stat -c %Y \"$ARCHIVE_PATH\")" +"%Y-%m-%dT%H:%M:%SZ")
	if [[ -n ${project_id} && ${project_id} != "null" ]]; then
		# Compare last_activity_at and archive date
		if [[ ${project_last_activity} > ${archive_mtime} ]]; then
			log "Repository ${norm_group_path}/${norm_project_name} is up to date (last_activity_at: ${project_last_activity}, archive: ${archive_mtime})"
			SKIPPED_UPTODATE+=("${norm_group_path}/${norm_project_name}")
			return 0
		else
			log "Repository ${norm_group_path}/${norm_project_name} differs from archive, will be overwritten (last_activity_at: ${project_last_activity}, archive: ${archive_mtime})"
			# Delete project
			curl --silent --request DELETE --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${project_id}"
			REPLACED_PROJECTS+=("${norm_group_path}/${norm_project_name}")
			sleep 2
		fi
	fi

	import_resp=$(curl --progress-bar --silent --request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		--form "path=${norm_project_name}" \
		--form "namespace=${norm_group_path}" \
		--form "name=${project_name}" \
		--form "file=@${ARCHIVE_PATH}" \
		"${GITLAB_URL}/api/v4/projects/import")
	if echo "${import_resp}" | grep -q '413 Request Entity Too Large'; then
		log "❌ Archive too large for ${norm_group_path}/${norm_project_name} (413 Request Entity Too Large)"
		FAILED_IMPORTS+=("${norm_group_path}/${norm_project_name} (413)")
		return 1
	fi
	log "Import response: ${import_resp}"

	import_id=$(echo "${import_resp}" | jq -r .id 2>/dev/null || true)
	if [[ -z ${import_id} || ${import_id} == "null" ]]; then
		log "❌ Failed to start import: ${import_resp}"
		FAILED_IMPORTS+=("${norm_group_path}/${norm_project_name} (import error)")
		return 1
	fi
	# Wait for import to finish
	max_wait=180 # max 3 minutes
	waited=0
	while true; do
		status_resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${import_id}/import")
		status=$(echo "${status_resp}" | jq -r .import_status)
		log "Import status: ${status}"
		if [[ ${status} == "finished" ]]; then
			log "✅ Import finished: ${norm_project_name}"
			break
		elif [[ ${status} == "failed" ]]; then
			log "❌ Import failed: ${norm_project_name}"
			FAILED_IMPORTS+=("${norm_group_path}/${norm_project_name} (import failed)")
			break
		fi
		if ((waited >= max_wait)); then
			log "⏱ Import timeout (${max_wait} sec): ${norm_project_name}"
			FAILED_IMPORTS+=("${norm_group_path}/${norm_project_name} (timeout)")
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done
}

# If an archive path is provided — import only it
if [[ $# -eq 1 ]]; then
	import_one "$1"
	result=$?
	echo
	echo "==== Summary ===="
	echo "Not imported (error/size): ${FAILED_IMPORTS[*]}"
	echo "Skipped (up to date): ${SKIPPED_UPTODATE[*]}"
	echo "Overwritten: ${REPLACED_PROJECTS[*]}"
	exit "${result}"
fi

# Bulk import of all archives from exports/
mapfile -t archives < <(find "${IMPORT_DIR}" -type f -iname '*.tar.gz')
log "Archives found: ${#archives[@]}"
for archive in "${archives[@]}"; do
	log "Archive to import: $archive"
	import_one "${archive}"
	log ""
done

log "==== Summary ===="
log "Not imported (error/size): ${FAILED_IMPORTS[*]}"
log "Skipped (up to date): ${SKIPPED_UPTODATE[*]}"
log "Overwritten: ${REPLACED_PROJECTS[*]}"
