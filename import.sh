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

# Dependency check
command -v jq >/dev/null 2>&1 || {
	echo >&2 "❌ jq is not installed. Install jq."
	exit 1
}
command -v curl >/dev/null 2>&1 || {
	echo >&2 "❌ curl is not installed. Install curl."
	exit 1
}

log() {
	local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
	echo "${msg}" | tee -a "${LOG_FILE}"
}

# Normalize path/name for GitLab namespace/path
normalize_gitlab_path() {
	local norm
	norm=$(echo "$1" | iconv -c -t ascii//TRANSLIT | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g; s/^-*//; s/-*$//')
	norm=$(echo "${norm}" | sed 's/-\{2,\}/-/g')
	norm=$(echo "${norm}" | sed 's/^[-_.]*//; s/[-_.]*$//')
	norm=$(echo "${norm}" | sed 's/\(\.git\|\.atom\)$//')
	norm=$(echo "${norm}" | sed 's/\.-/./g; s/-\././g')
	echo "${norm}"
}

normalize_segment() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[ _]/-/g; s/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//'
}

# Recursively create nested groups, return "<group_id>:<full_path>"
get_or_create_group() {
	local full_path="$1"
	local parent_id=""
	local current_path=""
	local last_group_id=""
	IFS='/' read -ra PARTS <<<"${full_path}"
	for part in "${PARTS[@]}"; do
		norm_part=$(normalize_gitlab_path "${part}")
		if [[ -z ${current_path} ]]; then
			current_path="${norm_part}"
		else
			current_path="${current_path}/${norm_part}"
		fi
		if [[ -n ${parent_id} ]]; then
			resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups/${parent_id}/subgroups")
			group_id=$(echo "${resp}" | jq -r ".[] | select(.path==\"${norm_part}\") | .id" | head -n1)
		else
			resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups?top_level_only=true&search=${norm_part}")
			group_id=$(echo "${resp}" | jq -r ".[] | select(.path==\"${norm_part}\") | .id" | head -n1)
		fi
		if [[ -z ${group_id} || ${group_id} == "null" ]]; then
			if [[ -n ${parent_id} ]]; then
				data=$(jq -nc --arg name "${part}" --arg path "${norm_part}" --argjson parent_id "${parent_id}" '{name: $name, path: $path, parent_id: $parent_id}')
			else
				data=$(jq -nc --arg name "${part}" --arg path "${norm_part}" '{name: $name, path: $path}')
			fi
			create_group_resp=$(curl --silent --show-error --request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
				--header "Content-Type: application/json" \
				--data "${data}" \
				"${GITLAB_URL}/api/v4/groups")
			group_id=$(echo "${create_group_resp}" | jq -r .id 2>/dev/null || true)
			if [[ -z ${group_id} || ${group_id} == "null" ]]; then
				if [[ $(echo "${create_group_resp}" | grep -c "has already been taken") -gt 0 ]]; then
					if [[ -n ${parent_id} ]]; then
						resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups/${parent_id}/subgroups")
						group_id=$(echo "${resp}" | jq -r ".[] | select(.path==\"${norm_part}\") | .id" | head -n1)
					else
						resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups?top_level_only=true&search=${norm_part}")
						group_id=$(echo "${resp}" | jq -r ".[] | select(.path==\"${norm_part}\") | .id" | head -n1)
					fi
					log "Group already exists: ${current_path} (id: ${group_id})" >&2
				else
					log "❌ Failed to create group ${current_path}: ${create_group_resp} (data: ${data})" >&2
					exit 1
				fi
			else
				log "Group created: ${current_path} (id: ${group_id})" >&2
			fi
		else
			log "Group already exists: ${current_path} (id: ${group_id})" >&2
		fi
		parent_id="${group_id}"
		last_group_id="${group_id}"
	done
	group_info=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups/${last_group_id}")
	path_with_namespace=$(echo "${group_info}" | jq -r .full_path)
	echo "${last_group_id}:${path_with_namespace}"
}

import_one() {
	ARCHIVE_PATH="$1"
	[[ -z ${ARCHIVE_PATH} || ! -f ${ARCHIVE_PATH} ]] && {
		log "❌ Specify archive path"
		exit 1
	}

	rel_path="${ARCHIVE_PATH#"${IMPORT_DIR}"/}"
	group_path="$(dirname "${rel_path}")"
	project_name="$(basename "${rel_path}" .tar.gz)"

	IFS='/' read -ra PARTS <<<"${group_path}"
	norm_group_path=""
	for part in "${PARTS[@]}"; do
		norm_part=$(normalize_gitlab_path "${part}")
		if [[ -z ${norm_group_path} ]]; then
			norm_group_path="${norm_part}"
		else
			norm_group_path="${norm_group_path}/${norm_part}"
		fi
	done
	norm_project_name=$(normalize_gitlab_path "${project_name}")

	log "────────────────────────────────────────────────────────────"
	log "➡️ Import: ${norm_group_path}/${norm_project_name}"

	# Check if group_path is a personal namespace
	user_info=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		"${GITLAB_URL}/api/v4/users?username=${group_path}")
	user_id=$(echo "${user_info}" | jq -r '.[0].id')
	username=$(echo "${user_info}" | jq -r '.[0].username')

	if [[ -n ${user_id} && ${user_id} != "null" && -n ${username} && ${username} != "null" ]]; then
		transfer_group="${username}-transfer"
		log "⚠️  Target namespace '${group_path}' is a personal namespace of user id ${user_id}. Import via API is not supported."
		log "➡️  Project will be imported to temporary group '${transfer_group}'. Please move it manually after import."
		# Check if project already exists in personal namespace
		personal_path="${username}/${norm_project_name}"
		personal_path_urlenc=$(echo "${personal_path}" | sed 's|/|%2F|g')
		personal_proj=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${personal_path_urlenc}")
		personal_proj_id=$(echo "${personal_proj}" | jq -r .id)
		personal_last_activity=$(echo "${personal_proj}" | jq -r .last_activity_at)
		archive_mtime=$(date -u -d "@$(stat -c %Y -- "${ARCHIVE_PATH}")" +"%Y-%m-%dT%H:%M:%SZ")
		if [[ -n ${personal_proj_id} && ${personal_proj_id} != "null" ]]; then
			if [[ ${personal_last_activity} > ${archive_mtime} ]]; then
				log "✅ Project already exists in personal namespace and is up to date (last_activity_at: ${personal_last_activity}, archive: ${archive_mtime}), skipping import."
				SKIPPED_UPTODATE+=("${personal_path}")
				return 0
			else
				log "♻️  Project exists in personal namespace but archive is newer, will update."
				group_path="${username}" # import directly into personal namespace
			fi
		else
			group_path="${transfer_group}" # as before
		fi
	fi

	# Continue with normal import logic, group_path may be changed above
	group_info_out=$(get_or_create_group "${group_path}")
	group_id=$(echo "${group_info_out}" | cut -d: -f1)
	gitlab_namespace=$(echo "${group_info_out}" | cut -d: -f2-)

	if [[ -z ${group_id} || ${group_id} == "null" ]]; then
		log "❌ Failed to get group id for import: ${gitlab_namespace}"
		FAILED_IMPORTS+=("${gitlab_namespace}/${norm_project_name} (group id not found)")
		return 1
	fi

	target_path="${gitlab_namespace}/${norm_project_name}"
	target_path_urlenc=$(echo "${target_path}" | sed 's|/|%2F|g')
	existing_proj=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${target_path_urlenc}")
	existing_proj_id=$(echo "${existing_proj}" | jq -r .id)
	project_last_activity=$(echo "${existing_proj}" | jq -r .last_activity_at)
	archive_mtime=$(date -u -d "@$(stat -c %Y -- "${ARCHIVE_PATH}")" +"%Y-%m-%dT%H:%M:%SZ")
	if [[ ! ${norm_project_name} =~ ^[a-z0-9_.-]+$ ]] || [[ ${norm_project_name} =~ ^[-_.] ]] || [[ ${norm_project_name} =~ [-_.]$ ]] || [[ ${norm_project_name} =~ (\.git|\.atom)$ ]]; then
		log "❌ Project name (path) '${norm_project_name}' does not meet GitLab requirements. Skipping."
		FAILED_IMPORTS+=("${gitlab_namespace}/${norm_project_name} (invalid path)")
		return 1
	fi
	if [[ -n ${existing_proj_id} && ${existing_proj_id} != "null" ]]; then
		if [[ ${project_last_activity} > ${archive_mtime} ]]; then
			log "Project ${target_path} is up to date (last_activity_at: ${project_last_activity}, archive: ${archive_mtime}), skipping import."
			SKIPPED_UPTODATE+=("${target_path}")
			return 0
		else
			log "Project ${target_path} will be updated (last_activity_at: ${project_last_activity}, archive: ${archive_mtime})"
			REPLACED_PROJECTS+=("${target_path}")
		fi
	fi

	import_resp=$(curl --progress-bar --request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		--form "path=${norm_project_name}" \
		--form "namespace=${group_id}" \
		--form "name=${project_name}" \
		--form "file=@${ARCHIVE_PATH}" \
		"${GITLAB_URL}/api/v4/projects/import")
	log "Import response: ${import_resp}"
	import_id=$(echo "${import_resp}" | jq -r .id 2>/dev/null || true)
	import_path=$(echo "${import_resp}" | jq -r .path_with_namespace 2>/dev/null || true)
	if [[ -z ${import_id} || ${import_id} == "null" ]]; then
		if [[ $(echo "${import_resp}" | grep -c "has already been taken") -gt 0 ]]; then
			log "⚠️  Project already exists: ${target_path}. Deleting and retrying import..."
			existing_proj=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${target_path_urlenc}")
			existing_proj_id=$(echo "${existing_proj}" | jq -r .id)
			if [[ -n ${existing_proj_id} && ${existing_proj_id} != "null" ]]; then
				del_resp=$(curl --silent --request DELETE --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
					"${GITLAB_URL}/api/v4/projects/${existing_proj_id}")
				log "🗑️  Deleted existing project id ${existing_proj_id}. Retrying import..."
				import_resp=$(curl --progress-bar --request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
					--form "path=${norm_project_name}" \
					--form "namespace=${group_id}" \
					--form "name=${project_name}" \
					--form "file=@${ARCHIVE_PATH}" \
					"${GITLAB_URL}/api/v4/projects/import")
				log "Import response (after delete): ${import_resp}"
				import_id=$(echo "${import_resp}" | jq -r .id 2>/dev/null || true)
				import_path=$(echo "${import_resp}" | jq -r .path_with_namespace 2>/dev/null || true)
				if [[ -z ${import_id} || ${import_id} == "null" ]]; then
					log "❌ Failed to import project after delete: ${import_resp}"
					FAILED_IMPORTS+=("${target_path} (import error after delete)")
					return 1
				fi
			else
				log "❌ Failed to get existing project id for delete: ${target_path}"
				FAILED_IMPORTS+=("${target_path} (cannot delete)")
				return 1
			fi
		else
			log "❌ Failed to start import: ${import_resp}"
			FAILED_IMPORTS+=("${gitlab_namespace}/${norm_project_name} (import error)")
			return 1
		fi
	fi

	log "Project imported as: ${import_path}"
	# Wait for import to finish
	max_wait=180
	waited=0
	while true; do
		status_resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${import_id}/import")
		status=$(echo "${status_resp}" | jq -r .import_status)
		log "Import status: ${status}"
		[[ ${status} == "finished" ]] && {
			log "✅ Import finished: ${norm_project_name}"
			break
		}
		[[ ${status} == "failed" ]] && {
			log "❌ Import failed: ${norm_project_name}"
			FAILED_IMPORTS+=("${gitlab_namespace}/${norm_project_name} (import failed)")
			break
		}
		((waited >= max_wait)) && {
			log "⏱ Import timeout (${max_wait} sec): ${norm_project_name}"
			FAILED_IMPORTS+=("${gitlab_namespace}/${norm_project_name} (timeout)")
			break
		}
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
	echo "Not imported (error/size): ${#FAILED_IMPORTS[@]}"
	echo "Skipped (up to date): ${#SKIPPED_UPTODATE[@]}"
	echo "Overwritten: ${#REPLACED_PROJECTS[@]}"
	exit "${result}"
fi

# Bulk import of all archives from exports/
mapfile -t archives < <(find "${IMPORT_DIR}" -type f -iname '*.tar.gz')
log "Archives found: ${#archives[@]}"
for archive in "${archives[@]}"; do
	log "Archive to import: ${archive}"
	import_one "${archive}"
	sleep 2
	log ""
done

log "==== Summary ===="
log "Not imported (error/size): ${#FAILED_IMPORTS[@]}"
log "Skipped (up to date): ${#SKIPPED_UPTODATE[@]}"
log "Overwritten: ${#REPLACED_PROJECTS[@]}"
