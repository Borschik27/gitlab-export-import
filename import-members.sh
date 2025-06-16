#!/bin/bash

LOG_FILE="import_members.log"
MEMBERS_DIR="members"
GITLAB_URL="${GITLAB_URL:-your-gitlab-url}"
PRIVATE_TOKEN="${PRIVATE_TOKEN:-your-access-token}"

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

# Helper function for URL encoding
urlencode() {
	local LANG=C
	local length="${#1}"
	for ((i = 0; i < length; i++)); do
		local c="${1:i:1}"
		case ${c} in
		[a-zA-Z0-9.~_-]) printf "${c}" ;;
		*) printf '%%%02X' "'${c}" ;;
		esac
	done
}

add_member() {
	local project_id=$1
	local user_id=$2
	local access_level=$3

	resp=$(curl --silent --output /dev/null --write-out "%{http_code}" \
		--request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		--data "user_id=${user_id}&access_level=${access_level}" \
		"${GITLAB_URL}/api/v4/projects/${project_id}/members")
	if [[ ${resp} == "201" || ${resp} == "409" ]]; then
		# 201 Created, 409 Already a member
		return 0
	else
		return 1
	fi
}

log "==== Importing project members from ${MEMBERS_DIR} ===="
processed=0
added=0
skipped=0
failed=0
notfound=0

normalize_segment() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[ _]/-/g; s/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//'
}

# Build mapping: normalized name -> real path
declare -A path_map
while IFS= read -r -d '' archive; do
	real_path=$(echo "${archive}" | sed 's|exports/||; s|\.tar\.gz$||')
	IFS='/' read -ra parts <<<"${real_path}"
	norm_parts=()
	for part in "${parts[@]}"; do
		norm_parts+=("$(normalize_segment "${part}")")
	done
	norm_path="${norm_parts[0]}"
	for ((i = 1; i < ${#norm_parts[@]}; i++)); do
		norm_path="${norm_path}__${norm_parts[${i}]}"
	done
	path_map["${norm_path}"]="${real_path}"
done < <(find exports/ -type f -name '*.tar.gz' -print0)

shopt -s nullglob
while IFS= read -r -d '' file; do
	((processed++))
	fname=$(basename "${file}")
	norm_name="${fname%.members.json}"
	project_path="${path_map[${norm_name}]}"

	if [[ -z ${project_path} ]]; then
		# Try to find a similar key (fuzzy match)
		found_key=""
		for k in "${!path_map[@]}"; do
			if [[ ${k,,} == *"${norm_name,,}"* ]] || [[ ${norm_name,,} == *"${k,,}"* ]]; then
				found_key="${k}"
				break
			fi
		done
		if [[ -n ${found_key} ]]; then
			project_path="${path_map[${found_key}]}"
			log "⚠️  Used fuzzy match: ${norm_name} → ${found_key} → ${project_path}"
		else
			log "❌ Can't find real project path for ${norm_name}"
			continue
		fi
	fi

	# Normalize path for GitLab API (already normalized above)
	norm_gitlab_path=$(echo "${project_path}" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g; s/--*/-/g; s/^-//; s/-$//')
	project_id=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		"${GITLAB_URL}/api/v4/projects/$(urlencode "${norm_gitlab_path}")" | jq -r .id)
	if [[ -z ${project_id} || ${project_id} == "null" ]]; then
		log "❌ Project not found in GitLab: ${project_path}"
		((failed++))
		continue
	fi
	log "➡️ Importing members for project ${project_path} (ID ${project_id})"
	count=$(jq 'length' "${file}")
	for ((i = 0; i < count; i++)); do
		username=$(jq -r ".[${i}].username" "${file}")
		access_level=$(jq -r ".[${i}].access_level" "${file}")
		if [[ ${access_level} == "50" ]]; then
			((skipped++))
			continue
		fi
		# Get user_id by username
		user_info=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/users?username=${username}")
		user_id=$(echo "${user_info}" | jq -r '.[0].id')
		if [[ -z ${user_id} || ${user_id} == "null" ]]; then
			log "⏭️  User '${username}' not found in system, skipping"
			((notfound++))
			continue
		fi
		if add_member "${project_id}" "${user_id}" "${access_level}"; then
			log "✅ Added user ${username} (id ${user_id}) with access_level ${access_level}"
			((added++))
		else
			log "❌ Failed to add user ${username} (id ${user_id}) with access_level ${access_level}"
			((failed++))
		fi
	done
done < <(find "${MEMBERS_DIR}" -type f -name '*.members.json' -print0)

log "==== Members import finished ===="
log "Total projects processed: ${processed}"
log "Total members added: ${added}"
log "Total skipped (owners): ${skipped}"
log "Total not found: ${notfound}"
log "Total failed: ${failed}"
