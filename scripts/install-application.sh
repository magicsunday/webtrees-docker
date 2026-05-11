#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# shellcheck source=scripts/configuration
source scripts/configuration

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"

# Required directories array
readonly REQUIRED_DIRS=(
    "data/media"
    "data/cache"
)

# File operations
copy_application_files() {
    if [[ ! -d "${APP_DIR}" ]]; then
        log_error "Application directory does not exist"
        exit 1
    fi

    cp -r "${APP_DIR}"/../setup/public/* "${APP_DIR}"/public
    cp -r "${APP_DIR}"/../setup/composer-core.json "${APP_DIR}/composer.json"

    # Patches consumed by cweagans/composer-patches must sit next to
    # composer.json — paths in composer.json's extra.patches are relative to it.
    cp -r "${APP_DIR}"/../setup/patches "${APP_DIR}"/patches
}

# Application installation
install_application() {
    log_success "Installing webtrees"

    composer install -d "${APP_DIR}" --no-ansi --no-interaction
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

    chown "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" "${target_dirs[@]}"
    chmod -R ug+rw "${target_dirs[@]}"
}

# Main execution
main() {
    validate_environment
    copy_application_files
    install_application

    # Conditionally set up configuration if using an existing database
    if [[ "${USE_EXISTING_DB:-1}" == "1" ]]; then
        setup_configuration
    else
        log_warning "Skipping initial configuration because no existing database will be used."
    fi

    setup_directories
    setup_directory_permissions

    log_success "Application installed successfully"
}

main
