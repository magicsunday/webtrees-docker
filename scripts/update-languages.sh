#!/usr/bin/env bash

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

## Prints out command arguments during execution.
#set -x

# Configuration
readonly WEBTREES_BASE="${APP_DIR}/vendor/fisharebest/webtrees"
readonly WEBTREES_REPO="https://github.com/fisharebest/webtrees.git"

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
setupLanguageDirectory() {
    mkdir -p "${WEBTREES_BASE}/resources/lang"
}

# Language files management
downloadLanguages() {
    logSuccess "Downloading language files"

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
setupLanguageDirectoryPermissions() {
    setfacl -R -m g:${LOCAL_GROUP_NAME}:rwx,d:g:${LOCAL_GROUP_NAME}:rwx "${WEBTREES_BASE}/resources/lang"

    chown -R "${LOCAL_USER_ID}:${LOCAL_GROUP_ID}" "${WEBTREES_BASE}/resources/lang"
    chmod -R ug+rw "${WEBTREES_BASE}/resources/lang"
}

# Main execution
main() {
    echo -e "\033[0;34m[+] Updating language files\033[0m"

    changeWorkingDirectory

    source scripts/configuration

    validateEnvironment
    setupLanguageDirectory
    downloadLanguages
    setupLanguageDirectoryPermissions

    logSuccess "The language files were successfully updated"
}

main
