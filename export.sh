#!/bin/bash

set -eu

LOG_FILE="export.log"
MAX_WAIT_SECONDS=180 # 3 min
MAX_EXPORTS_PER_MINUTE=6
MAX_EXPORT_RETRIES=3

# GitLab URL, Token, Export Dir
GITLAB_URL="${GITLAB_URL:-your-gitlab-url}"
PRIVATE_TOKEN="${PRIVATE_TOKEN:-your-access-token}"
EXPORT_DIR="${EXPORT_DIR:-exports}"

export_count=0
start_time=$(date +%s)

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

check_export_rate_limit() {
	current_time=$(date +%s)
	elapsed=$((current_time - start_time))

	if ((export_count >= MAX_EXPORTS_PER_MINUTE)); then
		if ((elapsed < 60)); then
			log "⏱ Limit reached ${MAX_EXPORTS_PER_MINUTE} exports/min. Pause $((60 - elapsed + 10)) sec..."
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
		--silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
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
	local seconds=0
	local retries=0

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
				if [[ -n ${timeout_file} ]]; then
					echo "${project_id}:${name}:${path}" >>"${timeout_file}"
				fi
				break
			fi
		elif [[ ${export_status} == "finished" ]]; then
			mkdir -p "${EXPORT_DIR}/${path}"
			log "📦 Download: ${EXPORT_DIR}/${path}/${name}.tar.gz"
			curl --progress-bar --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
				"${GITLAB_URL}/api/v4/projects/${project_id}/export/download" \
				--output "${EXPORT_DIR}/${path}/${name}.tar.gz"
			log "✅ Export completed: ${EXPORT_DIR}/${path}/${name}.tar.gz"
			break
		elif ((seconds >= MAX_WAIT_SECONDS)); then
			log "⏱ Export timeout (${MAX_WAIT_SECONDS} sec): ${name}. Skipping..."
			if [[ -n ${timeout_file} ]]; then
				echo "${project_id}:${name}:${path}" >>"${timeout_file}"
			fi
			break
		else
			if ((seconds % 30 == 0)); then
				log "⌛ ${name}: waiting for export ${seconds}s... (status: ${export_status})"
			fi
			sleep 5
			seconds=$((seconds + 5))
		fi
	done
}

# Getting all groups with subgroups and pagination
group_ids=()
page=1
while :; do
	response=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		"${GITLAB_URL}/api/v4/groups?all_available=true&per_page=100&page=${page}")
	count=$(echo "${response}" | jq 'length')
	if [[ ${count} -eq 0 ]]; then break; fi

	ids=$(echo "${response}" | jq -r '.[].id')
	for id in ${ids}; do
		group_ids+=("${id}")
	done

	page=$((page + 1))
done

# Processing each group
for GROUP_ID in "${group_ids[@]}"; do
	log "📁 Group Processing ID: ${GROUP_ID}"

	page=1
	while :; do
		projects=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
			"${GITLAB_URL}/api/v4/groups/${GROUP_ID}/projects?include_subgroups=true&per_page=100&page=${page}")

		count=$(echo "${projects}" | jq 'length')
		if [[ ${count} -eq 0 ]]; then break; fi
		log "📂 Found ${count} projects on page ${page} for group ID ${GROUP_ID}"

		echo "${projects}" | jq -c '.[]' | while read -r project; do
			id=$(echo "${project}" | jq -r .id)
			name=$(echo "${project}" | jq -r .name)
			path_with_namespace=$(echo "${project}" | jq -r .path_with_namespace)
			namespace_path=$(dirname "${path_with_namespace}")
			export_path="${EXPORT_DIR}/${namespace_path}/${name}.tar.gz"

			# # Log export status for debugging
			# export_status=$(echo "${project}" | jq -r .export_status)
			# log "DEBUG: ${name} (ID: ${id}) export_status: ${export_status}"

			last_activity_at=$(echo "${project}" | jq -r .last_activity_at)
			if [[ -f ${export_path} ]]; then
				project_time=$(date -d "${last_activity_at}" +%s 2>/dev/null)
				archive_time=$(stat -c %Y "${export_path}")
				if [[ -n ${project_time} && ${project_time} -le ${archive_time} ]]; then
					log "⏭  The repository is already retrieved and has not been changed: ${export_path} (last_activity_at: ${last_activity_at})"
					continue
				fi
			fi

			# If export status is undefined, initiate export only if project was really updated or archive is missing
			if [[ -z ${export_status} || ${export_status} == "null" || ${export_status} == "none" ]]; then
				log "🔄 Export not initiated (or status null), initiating export!"
				log "────────────────────────────────────────────────────────────"
				log "➡️ Project export ${path_with_namespace} (ID ${id})"
				export_project "${id}"
				sleep 10
				download_export "${id}" "${name}" "${namespace_path}" "${timeout_repos_file}"
				continue
			fi

			log "────────────────────────────────────────────────────────────"
			log "➡️ Project export ${path_with_namespace} (ID ${id})"
			export_project "${id}"
			sleep 10
			download_export "${id}" "${name}" "${namespace_path}" "${timeout_repos_file}"
		done

		# After processing the group, if there was no export/download, log this explicitly
		if [[ ${count} -eq 0 ]]; then
			log "There are no projects for export in group ID ${GROUP_ID}."
		fi

		page=$((page + 1))
	done
done

# Output the list of repositories with timeout after completion
if [[ -s ${timeout_repos_file} ]]; then
	log "\nList of repositories skipped due to export timeout:"
	while IFS=":" read -r id name namespace_path; do
		log "- ${namespace_path}/${name} (ID: ${id})"
		log "  Manual export via API:"
		log "    curl --request POST --header 'PRIVATE-TOKEN: ${PRIVATE_TOKEN}' '${GITLAB_URL}/api/v4/projects/${id}/export'"
		log "    curl --header 'PRIVATE-TOKEN: ${PRIVATE_TOKEN}' '${GITLAB_URL}/api/v4/projects/${id}/export' | jq .export_status"
		log "    curl --progress-bar --header 'PRIVATE-TOKEN: ${PRIVATE_TOKEN}' '${GITLAB_URL}/api/v4/projects/${id}/export/download' --output '${EXPORT_DIR}/${namespace_path}/${name}.tar.gz'"
	done <"${timeout_repos_file}"
fi
rm -f "${timeout_repos_file}"
