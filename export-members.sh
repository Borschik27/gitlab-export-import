#!/bin/bash

LOG_FILE="export_members.log"
MEMBERS_DIR="members"
GITLAB_URL="${GITLAB_URL:-your-gitlab-url}"
PRIVATE_TOKEN="${PRIVATE_TOKEN:-your-access-token}"

mkdir -p "${MEMBERS_DIR}"

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

# Get all projects from all groups (including subgroups)
get_all_group_projects() {
	local page=1
	while :; do
		resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/projects?simple=true&per_page=100&page=${page}&membership=false")
		count=$(echo "${resp}" | jq 'length')
		[[ ${count} -eq 0 ]] && break
		echo "${resp}" | jq -c '.[]'
		page=$((page + 1))
	done
}

# Get all user IDs
get_all_users() {
	local page=1
	local user_ids=()
	while :; do
		response=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/users?per_page=100&page=${page}")
		count=$(echo "${response}" | jq 'length')
		[[ ${count} -eq 0 ]] && break
		ids=$(echo "${response}" | jq -r '.[].id')
		for id in ${ids}; do user_ids+=("${id}"); done
		page=$((page + 1))
	done
	printf "%s\n" "${user_ids[@]}"
}

# Get all personal projects for a user
get_user_projects() {
	local user_id=$1
	local page=1
	while :; do
		resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/users/${user_id}/projects?per_page=100&page=${page}")
		count=$(echo "${resp}" | jq 'length')
		[[ ${count} -eq 0 ]] && break
		echo "${resp}" | jq -c '.[]'
		page=$((page + 1))
	done
}

normalize_segment() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[ _]/-/g; s/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//'
}

export_project_members() {
	local project_id=$1
	local project_path=$2

	IFS='/' read -ra parts <<<"${project_path}"
	norm_parts=()
	for part in "${parts[@]}"; do
		norm_parts+=("$(normalize_segment "${part}")")
	done
	norm_path="${norm_parts[0]}"
	for ((i = 1; i < ${#norm_parts[@]}; i++)); do
		norm_path="${norm_path}__${norm_parts[${i}]}"
	done
	out_file="${MEMBERS_DIR}/${norm_path}.members.json"

	log "➡️ Exporting members for project ${project_path} (ID ${project_id})"
	members=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		"${GITLAB_URL}/api/v4/projects/${project_id}/members/all")
	if [[ -z ${members} || ${members} == "null" ]]; then
		log "❌ Failed to get members for project ${project_path} (ID ${project_id})"
		return 1
	fi
	echo "${members}" | jq '.' >"${out_file}"
	count=$(echo "${members}" | jq 'length')
	log "✅ Saved ${count} members to ${out_file}"
}

log "==== Exporting all project members (groups and personal) ===="
processed=0
failed=0

# Export members for all group/shared projects
mapfile -t group_projects < <(get_all_group_projects)
log "Found ${#group_projects[@]} group/shared projects."
for project in "${group_projects[@]}"; do
	processed=$((processed + 1))
	id=$(echo "${project}" | jq -r .id)
	path_with_namespace=$(echo "${project}" | jq -r .path_with_namespace)
	if export_project_members "${id}" "${path_with_namespace}"; then
		:
	else
		failed=$((failed + 1))
	fi
done

# Export members for all personal projects
mapfile -t all_users < <(get_all_users)
log "Found ${#all_users[@]} users."
for user_id in "${all_users[@]}"; do
	mapfile -t user_projects < <(get_user_projects "${user_id}")
	for project in "${user_projects[@]}"; do
		processed=$((processed + 1))
		id=$(echo "${project}" | jq -r .id)
		path_with_namespace=$(echo "${project}" | jq -r .path_with_namespace)
		if export_project_members "${id}" "${path_with_namespace}"; then
			:
		else
			failed=$((failed + 1))
		fi
	done
done

log "==== Members export finished ===="
log "Total projects processed: ${processed}"
log "Total failed: ${failed}"
