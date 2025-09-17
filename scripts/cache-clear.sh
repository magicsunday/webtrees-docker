#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# shellcheck source=scripts/configuration
source scripts/configuration

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"

# Cache directory management
setup_directories() {
    log_success "Removing existing cache directory structure"
    rm -rf "${WEBTREES_BASE}/data/cache"

    log_success "Setting up new cache directory structure"
    mkdir -p "${WEBTREES_BASE}/data/cache"
}

# Permission management
setup_directory_permissions() {
    log_success "Setting up directory permissions"

    chown -R "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" "${WEBTREES_BASE}/data/cache"
    chmod -R ug+rw "${WEBTREES_BASE}/data/cache"
}

# Main execution
main() {
    printf "\033[0;34m[+] Clear webtrees cache directory\033[0m\n"

    validate_environment
    setup_directories
    setup_directory_permissions

    log_success "Setting up cache directory completed successfully"
}

main
