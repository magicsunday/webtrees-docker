#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"
readonly WEBTREES_REPO="https://github.com/fisharebest/webtrees.git"

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
setup_language_directory() {
    mkdir -p "${WEBTREES_BASE}/resources/lang"
}

# Language files management
download_languages() {
    log_success "Downloading language files"

    rm -rf webtrees-languages

    git clone --quiet --no-checkout --depth=1 --filter=tree:0 \
        "${WEBTREES_REPO}" webtrees-languages

    cd webtrees-languages || exit 1
    git sparse-checkout set --no-cone /resources/lang
    git checkout --quiet --no-progress > /dev/null 2>&1
    cd - > /dev/null || exit 1

    cp -rf webtrees-languages/resources/lang/* "${WEBTREES_BASE}/resources/lang"
    rm -rf webtrees-languages
}

# Permission management
setup_language_directory_permissions() {
    setfacl -R -m g:"${LOCAL_GROUP_NAME}":rwx,d:g:"${LOCAL_GROUP_NAME}":rwx "${WEBTREES_BASE}/resources/lang"

    chown -R "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" "${WEBTREES_BASE}/resources/lang"
    chmod -R ug+rw "${WEBTREES_BASE}/resources/lang"
}

# Main execution
main() {
    printf "\033[0;34m[+] Updating language files\033[0m\n"

    change_working_directory

    # shellcheck source=scripts/configuration
    source scripts/configuration

    validate_environment
    setup_language_directory
    download_languages
    setup_language_directory_permissions

    log_success "The language files were successfully updated"
}

main
