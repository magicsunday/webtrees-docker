#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"

# Required directories array
readonly REQUIRED_DIRS=(
    "data/media"
    "data/cache"
)

# Change working directory
change_working_directory() {
    local current_dir app_basename base_dir
    current_dir=$(pwd)

    # Extract only the last part of APP_DIR, e.g. "app" from "./app"
    app_basename=$(basename "${APP_DIR}")

    # Check if the current directory ends with this part
    if [[ "${current_dir}" == */${app_basename} ]]; then
        base_dir=$(dirname "${current_dir}")
        cd "${base_dir}"
    fi
}

# Directory management
setup_directories() {
    log_success "Setting up directory structure"

    rm -rf "${WEBTREES_BASE}/data/cache"

    local dir
    for dir in "${REQUIRED_DIRS[@]}"; do
        mkdir -p "${WEBTREES_BASE}/${dir}"
    done
}

# Permission management
setup_directory_permissions() {
    log_success "Setting up directory permissions"

    local target_dirs=("${WEBTREES_BASE}/data/media" "${WEBTREES_BASE}/data/cache")

    setfacl -m g:"${LOCAL_GROUP_NAME}":rwx,d:g:"${LOCAL_GROUP_NAME}":rwx "${WEBTREES_BASE}/data/cache"

    chown "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" "${target_dirs[@]}"
    chmod -R ug+rw "${target_dirs[@]}"
}

# Main execution
main() {
    printf "\033[0;34m[+] Updating webtrees configuration\033[0m\n"

    change_working_directory

    # shellcheck source=scripts/configuration
    source scripts/configuration

    validate_environment
    setup_directories
    setup_directory_permissions

    log_success "The application was successfully updated"
}

main
