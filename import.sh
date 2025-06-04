#!/bin/bash
# Импорт проектов из каталога exports/ или одного архива в GitLab через projects/import
# Использование:
#   ./import.sh                 # массовый импорт всех архивов из exports/
#   ./import.sh путь/к/архиву   # импорт только одного архива

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

# Рекурсивное создание вложенных групп
get_or_create_group() {
  local full_path="$1"
  local parent_id=""
  local current_path=""
  IFS='/' read -ra PARTS <<< "$full_path"
  for part in "${PARTS[@]}"; do
    if [[ -z "$current_path" ]]; then
      current_path="$part"
    else
      current_path="$current_path/$part"
    fi
    # Проверяем, есть ли такая группа
    resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/groups/${current_path}")
    group_id=$(echo "$resp" | jq -r .id 2>/dev/null || true)
    if [[ -z "$group_id" || "$group_id" == "null" ]]; then
      # Создаём группу
      data="{\"name\": \"$part\", \"path\": \"$part\""
      if [[ -n "$parent_id" ]]; then
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
      if [[ -z "$group_id" || "$group_id" == "null" ]]; then
        log "❌ Не удалось создать группу $current_path: $create_group_resp"
        exit 1
      fi
      log "Группа создана: $current_path (id: $group_id)"
    else
      log "Группа уже существует: $current_path (id: $group_id)"
    fi
    parent_id="$group_id"
  done
  echo "$group_id"
}

import_one() {
	ARCHIVE_PATH="$1"
	if [[ -z ${ARCHIVE_PATH} || ! -f ${ARCHIVE_PATH} ]]; then
		log "❌ Укажите путь к архиву .tar.gz (например, ${IMPORT_DIR}/<proj_id_name>/<proj_name>.tar.gz)"
		exit 1
	fi
	rel_path="${ARCHIVE_PATH#"${IMPORT_DIR}/"}"
	group_path="$(dirname "${rel_path}")"
	project_name="$(basename "${rel_path}" .tar.gz)"

	log "────────────────────────────────────────────────────────────"
	log "➡️ Импорт: ${group_path}/${project_name}"

	# 1. Рекурсивно создаём группу (и получаем id)
	group_id=$(get_or_create_group "$group_path")

	# 2. Проверка существующего проекта
	get_proj_resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects?search=${project_name}")
	project_id=$(echo "${get_proj_resp}" | jq -r ".[] | select(.path_with_namespace==\"${group_path}/${project_name}\") | .id" | head -n1)
	project_last_activity=$(echo "${get_proj_resp}" | jq -r ".[] | select(.path_with_namespace==\"${group_path}/${project_name}\") | .last_activity_at" | head -n1)
	archive_mtime=$(date -u -d "@$(stat -c %Y "$ARCHIVE_PATH")" +"%Y-%m-%dT%H:%M:%SZ")
	if [[ -n ${project_id} && ${project_id} != "null" ]]; then
		# Сравниваем last_activity_at и дату архива
		if [[ ${project_last_activity} > ${archive_mtime} ]]; then
			log "Репозиторий ${group_path}/${project_name} актуален (last_activity_at: ${project_last_activity}, архив: ${archive_mtime})"
			SKIPPED_UPTODATE+=("${group_path}/${project_name}")
			return 0
		else
			log "Репозиторий ${group_path}/${project_name} отличается от архива, будет перезаписан (last_activity_at: ${project_last_activity}, архив: ${archive_mtime})"
			# Удаляем проект
			curl --silent --request DELETE --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${project_id}"
			REPLACED_PROJECTS+=("${group_path}/${project_name}")
			sleep 2
		fi
	fi

	# 3. Импортируем проект через projects/import
	import_resp=$(curl --progress-bar --silent --request POST --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" \
		--form "path=${project_name}" \
		--form "namespace=${group_path}" \
		--form "file=@${ARCHIVE_PATH}" \
		"${GITLAB_URL}/api/v4/projects/import")
	if echo "${import_resp}" | grep -q '413 Request Entity Too Large'; then
		log "❌ Слишком большой архив для ${group_path}/${project_name} (413 Request Entity Too Large)"
		FAILED_IMPORTS+=("${group_path}/${project_name} (413)")
		return 1
	fi
	log "Ответ на импорт: ${import_resp}"

	# 4. Проверяем статус импорта
	import_id=$(echo "${import_resp}" | jq -r .id 2>/dev/null || true)
	if [[ -z ${import_id} || ${import_id} == "null" ]]; then
		log "❌ Не удалось запустить импорт: ${import_resp}"
		FAILED_IMPORTS+=("${group_path}/${project_name} (import error)")
		return 1
	fi
	# Ждём завершения импорта
	max_wait=180 # максимум 3 минуты
	waited=0
	while true; do
		status_resp=$(curl --silent --header "PRIVATE-TOKEN: ${PRIVATE_TOKEN}" "${GITLAB_URL}/api/v4/projects/${import_id}/import")
		status=$(echo "${status_resp}" | jq -r .import_status)
		log "Статус импорта: ${status}"
		if [[ ${status} == "finished" ]]; then
			log "✅ Импорт завершён: ${project_name}"
			break
		elif [[ ${status} == "failed" ]]; then
			log "❌ Импорт не удался: ${project_name}"
			FAILED_IMPORTS+=("${group_path}/${project_name} (import failed)")
			break
		fi
		if ((waited >= max_wait)); then
			log "⏱ Таймаут ожидания импорта (${max_wait} сек): ${project_name}"
			FAILED_IMPORTS+=("${group_path}/${project_name} (timeout)")
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done
}

# Если передан путь к архиву — импортируем только его
if [[ $# -eq 1 ]]; then
	import_one "$1"
	result=$?
	echo
	echo "==== Итог ===="
	echo "Не импортированы (ошибка/размер): ${FAILED_IMPORTS[*]}"
	echo "Пропущены (актуальны): ${SKIPPED_UPTODATE[*]}"
	echo "Перезаписаны: ${REPLACED_PROJECTS[*]}"
	exit "${result}"
fi

# Массовый импорт всех архивов из каталога exports/
mapfile -t archives < <(find "${IMPORT_DIR}" -type f -iname '*.tar.gz')
log "Найдено архивов: ${#archives[@]}"
for archive in "${archives[@]}"; do
	log "Архив для импорта: $archive"
	import_one "${archive}"
	log ""
done

log "==== Итог ===="
log "Не импортированы (ошибка/размер): ${FAILED_IMPORTS[*]}"
log "Пропущены (актуальны): ${SKIPPED_UPTODATE[*]}"
log "Перезаписаны: ${REPLACED_PROJECTS[*]}"
