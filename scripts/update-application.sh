#!/usr/bin/env bash

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

## Prints out command arguments during execution.
#set -x

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"

# Required directories array
readonly REQUIRED_DIRS=(
    "data/media"
    "data/cache"
)

# Change working directory
changeWorkingDirectory() {
    CURRENT_DIR=$(pwd)

    # Extract only the last part of APP_DIR, e.g. "app" from "./app"
    APP_BASENAME=$(basename "$APP_DIR")

    # Check if the current directory ends with this part
    if [[ "$CURRENT_DIR" == */$APP_BASENAME ]]; then
        BASE_DIR=$(dirname "$CURRENT_DIR")

        cd "$BASE_DIR"
    fi
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

    setfacl -m g:${LOCAL_GROUP_NAME}:rwx,d:g:${LOCAL_GROUP_NAME}:rwx "${WEBTREES_BASE}/data/cache"

    chown "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" ${target_dirs}
    chmod -R ug+rw ${target_dirs}
}

# Main execution
main() {
    echo -e "\033[0;34m[+] Updating webtrees configuration\033[0m"

    changeWorkingDirectory

    source scripts/configuration

    validateEnvironment
    setupConfiguration
    setupDirectories
    setupDirectoryPermissions

    logSuccess "The application was successfully updated"
}

main
