#!/usr/bin/env bash

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

## Prints out command arguments during execution.
#set -x

source scripts/configuration

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"

# Cache directory management
setupDirectories() {
    logSuccess "Removing existing cache directory structure"
    rm -rf "${WEBTREES_BASE}/data/cache"

    logSuccess "Setting up new cache directory structure"
    mkdir -p "${WEBTREES_BASE}/data/cache"
}

# Permission management
setupDirectoryPermissions() {
    chown -R "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" "${WEBTREES_BASE}/data/cache"
    chmod -R ug+rw "${WEBTREES_BASE}/data/cache"
}

# Main execution
main() {
    echo -e "\033[0;34m[+] Clear webtrees cache directory\033[0m"

    validateEnvironment
    setupDirectories
    setupDirectoryPermissions

    logSuccess "Setting up cache directory completed successfully"
}

main
