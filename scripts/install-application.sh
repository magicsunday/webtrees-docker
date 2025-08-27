#!/usr/bin/env bash

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

## Prints out command arguments during execution.
#set -x

source scripts/configuration

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"

# Required directories array
readonly REQUIRED_DIRS=(
    "data/media"
    "data/cache"
)

# File operations
copyApplicationFiles() {
    if [[ ! -d "${APP_DIR}" ]]; then
        logError "Application directory does not exist"
        exit 1
    fi

    cp -r "${APP_DIR}"/../setup/public/* "${APP_DIR}"/public
    cp -r "${APP_DIR}"/../setup/composer.json "${APP_DIR}"
}

# Application installation
installApplication() {
    logSuccess "Installing webtrees"

    composer install -d "${APP_DIR}" --no-ansi --no-interaction

    cd "${APP_DIR}" || exit 1

    rm -rf html
    ln -sf public html

    cd - > /dev/null || exit 1
}

# Directory management
setupDirectories() {
    logSuccess "Setting up directory structure"

    rm -rf "${WEBTREES_BASE}/data/cache"

    for dir in "${REQUIRED_DIRS[@]}"; do
        mkdir -p "${WEBTREES_BASE}/${dir}"
    done
}

# Permission management
setupDirectoryPermissions() {
    local target_dirs="${WEBTREES_BASE}/data/media ${WEBTREES_BASE}/data/cache"

    chown "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" ${target_dirs}
    chmod -R ug+rw ${target_dirs}
}

# Main execution
main() {
    validateEnvironment
    copyApplicationFiles
    installApplication
    setupConfiguration
    setupDirectories
    setupDirectoryPermissions
    logSuccess "Application installed successfully"
}

main
