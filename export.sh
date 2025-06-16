#!/bin/bash

LOG_FILE="export.log"
MAX_WAIT_SECONDS=180 # 3 min
MAX_EXPORTS_PER_MINUTE=6
MAX_EXPORT_RETRIES=3

GITLAB_URL="${GITLAB_URL:-your-gitlab-url}"
PRIVATE_TOKEN="${PRIVATE_TOKEN:-your-access-token}"
EXPORT_DIR="${EXPORT_DIR:-exports}"

export_count=0
start_time=$(date +%s)

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

total_processed=0
total_exported=0
total_skipped=0
total_errors=0

check_export_rate_limit() {
	local current_time elapsed
	current_time=$(date +%s)
	elapsed=$((current_time - start_time))
	if ((export_count >= MAX_EXPORTS_PER_MINUTE)); then
		if ((elapsed < 60)); then
			log "⏱ Rate limit reached (${MAX_EXPORTS_PER_MINUTE}/min). Sleeping $((60 - elapsed + 10)) sec..."
			sleep $((60 - elapsed + 10))
		fi
		export_count=0
		start_time=$(date +%s)
	fi
}

export_project() {
	local project_id=$1
	check_export_rate_limit
	curl --request POST --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		"${GITLAB_URL}/api/v4/projects/${project_id}/export" >/dev/null
	export_count=$((export_count + 1))
}

timeout_repos_file="timeout_repos.txt"
true >"${timeout_repos_file}"

download_export() {
	local project_id=$1
	local name=$2
	local path=$3
	local timeout_file=$4

	log "⏳ Waiting for export: ${EXPORT_DIR}/${path}/${name} ..."
	local seconds=0 retries=0

	while true; do
		export_response=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/projects/${project_id}/export")
		export_status=$(echo "${export_response}" | jq -r .export_status)

		if [[ -z ${export_status} || ${export_status} == "null" || ${export_status} == "none" ]]; then
			log "🔄 Export not initiated (or status null), sending export request..."
			curl --request POST --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
				"${GITLAB_URL}/api/v4/projects/${project_id}/export" >/dev/null
			sleep 5
		elif [[ ${export_status} == "failed" ]]; then
			if ((retries < MAX_EXPORT_RETRIES)); then
				retries=$((retries + 1))
				log "❌ Export failed for ${name}, retry ${retries}/${MAX_EXPORT_RETRIES}..."
				curl --request POST --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
					"${GITLAB_URL}/api/v4/projects/${project_id}/export" >/dev/null
				sleep 10
				continue
			else
				log "❌ Export error: ${name} (retry limit reached)"
				[[ -n ${timeout_file} ]] && echo "${project_id}:${name}:${path}" >>"${timeout_file}"
				break
			fi
		elif [[ ${export_status} == "finished" ]]; then
			mkdir -p "${EXPORT_DIR}/${path}"
			log "📦 Download: ${EXPORT_DIR}/${path}/${name}.tar.gz"
			curl --progress-bar --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
				"${GITLAB_URL}/api/v4/projects/${project_id}/export/download" \
				--output "${EXPORT_DIR}/${path}/${name}.tar.gz"
			log "✅ Export completed: ${EXPORT_DIR}/${path}/${name}.tar.gz"
			break
		elif ((seconds >= MAX_WAIT_SECONDS)); then
			log "⏱ Export timeout (${MAX_WAIT_SECONDS} sec): ${name}. Skipping..."
			[[ -n ${timeout_file} ]] && echo "${project_id}:${name}:${path}" >>"${timeout_file}"
			break
		else
			((seconds % 30 == 0)) && log "⌛ ${name}: waiting for export ${seconds}s... (status: ${export_status})"
			sleep 5
			seconds=$((seconds + 5))
		fi
	done
}

normalize_segment() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[ _]/-/g; s/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//'
}

# Get all group IDs (including subgroups)
group_ids=()
page=1
while :; do
	response=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		"${GITLAB_URL}/api/v4/groups?all_available=true&per_page=100&page=${page}")
	count=$(echo "${response}" | jq 'length')
	[[ ${count} -eq 0 ]] && break
	ids=$(echo "${response}" | jq -r '.[].id')
	for id in ${ids}; do group_ids+=("${id}"); done
	page=$((page + 1))
done

# Export all group projects
for GROUP_ID in "${group_ids[@]}"; do
	processed_count=0
	exported_count=0
	skipped_count=0
	log "📁 Processing group ID: ${GROUP_ID}"

	page=1
	while :; do
		projects=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/groups/${GROUP_ID}/projects?include_subgroups=true&per_page=100&page=${page}")
		count=$(echo "${projects}" | jq 'length')
		[[ ${count} -eq 0 ]] && break
		log "📂 Found ${count} projects on page ${page} for group ID ${GROUP_ID}"

		mapfile -t project_lines < <(echo "${projects}" | jq -c '.[]')
		for project in "${project_lines[@]}"; do
			processed_count=$((processed_count + 1))
			id=$(echo "${project}" | jq -r .id)
			name=$(echo "${project}" | jq -r .name)
			path_with_namespace=$(echo "${project}" | jq -r .path_with_namespace)
			namespace_path=$(dirname "${path_with_namespace}")
			export_path="${EXPORT_DIR}/${namespace_path}/${name}.tar.gz"
			last_activity_at=$(echo "${project}" | jq -r .last_activity_at)
			if [[ -f ${export_path} ]]; then
				project_time=$(date -d "${last_activity_at}" +%s 2>/dev/null)
				archive_time=$(stat -c %Y "${export_path}")
				if [[ -n ${project_time} && ${project_time} -le ${archive_time} ]]; then
					log "⏭  Already up-to-date: ${export_path} (last_activity_at: ${last_activity_at})"
					skipped_count=$((skipped_count + 1))
					continue
				fi
			fi
			log "────────────────────────────────────────────────────────────"
			log "➡️ Exporting project ${path_with_namespace} (ID ${id})"
			export_project "${id}"
			sleep 10
			download_export "${id}" "${name}" "${namespace_path}" "${timeout_repos_file}"
			exported_count=$((exported_count + 1))
		done
		page=$((page + 1))
	done
	log "--- Group ID ${GROUP_ID} summary: Processed: ${processed_count}, Exported: ${exported_count}, Skipped: ${skipped_count} ---"
	total_processed=$((total_processed + processed_count))
	total_exported=$((total_exported + exported_count))
	total_skipped=$((total_skipped + skipped_count))
done

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

# Export all personal projects for each user
export_user_projects() {
	local USER_ID=$1
	local page=1
	local processed_count=0
	local exported_count=0
	local skipped_count=0
	log "👤 Exporting personal projects for user ID: ${USER_ID}"
	while :; do
		projects=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/users/${USER_ID}/projects?per_page=100&page=${page}")
		if [[ -z ${projects} ]] || ! echo "${projects}" | jq empty 2>/dev/null; then
			log "❌ Error: Invalid or empty response from API for user ${USER_ID} (page ${page})"
			break
		fi
		count=$(echo "${projects}" | jq 'length')
		[[ ${count} -eq 0 ]] && break
		mapfile -t project_lines < <(echo "${projects}" | jq -c '.[]')
		for project in "${project_lines[@]}"; do
			processed_count=$((processed_count + 1))
			id=$(echo "${project}" | jq -r .id)
			name=$(echo "${project}" | jq -r .name)
			path_with_namespace=$(echo "${project}" | jq -r .path_with_namespace)
			namespace_path=$(dirname "${path_with_namespace}")
			export_path="${EXPORT_DIR}/${namespace_path}/${name}.tar.gz"
			last_activity_at=$(echo "${project}" | jq -r .last_activity_at)
			if [[ -f ${export_path} ]]; then
				project_time=$(date -d "${last_activity_at}" +%s 2>/dev/null)
				archive_time=$(stat -c %Y "${export_path}")
				if [[ -n ${project_time} && ${project_time} -le ${archive_time} ]]; then
					log "⏭  Already up-to-date: ${export_path} (last_activity_at: ${last_activity_at})"
					skipped_count=$((skipped_count + 1))
					continue
				fi
			fi
			log "────────────────────────────────────────────────────────────"
			log "➡️ Exporting personal project ${path_with_namespace} (ID ${id})"
			export_project "${id}"
			sleep 10
			download_export "${id}" "${name}" "${namespace_path}" "${timeout_repos_file}"
			exported_count=$((exported_count + 1))
		done
		page=$((page + 1))
	done
	log "--- User ID ${USER_ID} summary: Processed: ${processed_count}, Exported: ${exported_count}, Skipped: ${skipped_count} ---"
	total_processed=$((total_processed + processed_count))
	total_exported=$((total_exported + exported_count))
	total_skipped=$((total_skipped + skipped_count))
}

# Export all personal projects after group projects
mapfile -t all_users < <(get_all_users) || true
log "Found ${#all_users[@]} users."
for uid in "${all_users[@]}"; do
	export_user_projects "${uid}"
done

# Output the list of repositories with timeout after completion
if [[ -s ${timeout_repos_file} ]]; then
	log "List of repositories skipped due to export timeout:"
	while IFS=":" read -r id name namespace_path; do
		log "- ${namespace_path}/${name} (ID: ${id})"
		log "  Manual export via API:"
		log "    curl --request POST --header 'PRIVATE-TOKEN: ${PRIVATE_TOKEN}' '${GITLAB_URL}/api/v4/projects/${id}/export'"
		log "    curl --header 'PRIVATE-TOKEN: ${PRIVATE_TOKEN}' '${GITLAB_URL}/api/v4/projects/${id}/export' | jq .export_status"
		log "    curl --progress-bar --header 'PRIVATE-TOKEN: ${PRIVATE_TOKEN}' '${GITLAB_URL}/api/v4/projects/${id}/export/download' --output '${EXPORT_DIR}/${namespace_path}/${name}.tar.gz'"
		total_errors=$((total_errors + 1))
	done <"${timeout_repos_file}"
fi
rm -f "${timeout_repos_file}"

log "==== Export finished for all groups and all personal projects ===="
log "==== Summary ===="
log "Total processed:   ${total_processed}"
log "Total exported:    ${total_exported}"
log "Total skipped:     ${total_skipped}"
log "Total with errors: ${total_errors}"
