#!/usr/bin/env bash

# User entrypoint script for Webtrees
# This script creates a local user and group within the container based on environment variables,
# sets up the user's environment, and executes commands as that user.

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

# Treats unset or undefined variables as an error when substituting (during parameter expansion).
set -u

# Displays a message when a task completes.
set -m

# Prevent masking an error in a pipeline
set -o pipefail

# Logging utilities
logSuccess() {
    echo -e "\033[0;32m ✔\033[0m $1"
}

logError() {
    echo -e "\033[0;31m ✘\033[0m $1" >&2
}

# Log a warning message to stderr with timestamp and color
logWarning() {
    echo -e "\033[0;33m ⚠\033[0m $1" >&2
}

# Set default values for environment variables
setDefaults() {
    if [ -z "${LOCAL_GROUP_NAME:-}" ]; then
        LOCAL_GROUP_NAME='www-data'
        logSuccess "Using default group name: ${LOCAL_GROUP_NAME}"
    fi

    if [ -z "${LOCAL_GROUP_ID:-}" ]; then
        LOCAL_GROUP_ID=82
        logSuccess "Using default group ID: ${LOCAL_GROUP_ID}"
    fi

    if [ -z "${LOCAL_USER_NAME:-}" ]; then
        LOCAL_USER_NAME=user
        logSuccess "Using default user name: ${LOCAL_USER_NAME}"
    fi

    if [ -z "${LOCAL_USER_ID:-}" ]; then
        LOCAL_USER_ID=1001
        logSuccess "Using default user ID: ${LOCAL_USER_ID}"
    fi

    # Set APP_BIN if APP_DIR is defined
    if [ -n "${APP_DIR:-}" ]; then
        APP_BIN="/var/www/html/app/vendor/bin"
        logSuccess "Setting up application binary directory to ${APP_BIN}"
    else
        APP_BIN=""
    fi

    # Set home directory and profile file
    HOME_DIR="/home/${LOCAL_USER_NAME}"
    FILE_PROFILE="${HOME_DIR}/.bashrc"
}

# Create the user and group
setupUserAndGroup() {
    logSuccess "Setting up user ${LOCAL_USER_NAME} (${LOCAL_USER_ID}) within group ${LOCAL_GROUP_NAME} (${LOCAL_GROUP_ID})"

    # Create the group (ignore errors if it already exists)
    if ! groupadd -r "${LOCAL_GROUP_NAME}" -g "${LOCAL_GROUP_ID}" >/dev/null 2>&1; then
        logWarning "Group ${LOCAL_GROUP_NAME} already exists or could not be created"
    fi

    # Create the user (ignore errors if it already exists)
    if ! useradd --no-log-init --create-home -u "${LOCAL_USER_ID}" -g "${LOCAL_GROUP_NAME}" \
        -s /bin/bash -d "${HOME_DIR}" "${LOCAL_USER_NAME}" >/dev/null 2>&1; then
        logWarning "User ${LOCAL_USER_NAME} already exists or could not be created"
    fi
}

# Setup the user's environment
setupUserEnvironment() {
    logSuccess "Setting up user environment in ${HOME_DIR}"

    # Copy mounted SSH files if they exist
    if [ -d /root/.ssh ]; then
        if ! cp -r /root/.ssh "${HOME_DIR}"; then
            logError "Failed to copy SSH files"
            return 1
        fi

        if ! chown "${LOCAL_USER_NAME}" -R "${HOME_DIR}"/.ssh; then
            logError "Failed to set ownership of SSH files"
            return 1
        fi
    fi

    # Export all environment variables except HOME, otherwise the user would still have /root
    # as their home directory after running su.
    if ! export | grep -v HOME >>"${FILE_PROFILE}"; then
        logError "Failed to export environment variables to user profile"
        return 1
    fi

    # Set working directory in user profile
    if ! echo -e "cd $PWD" >>"${FILE_PROFILE}"; then
        logError "Failed to set working directory in user profile"
        return 1
    fi

    # Set PATH in user profile
    if ! echo -e "export PATH=\"${APP_BIN:+$APP_BIN:}/root/.composer/vendor/bin:\$HOME/.composer/vendor/bin:\$HOME/bin:\$PATH\"" >>"${FILE_PROFILE}"; then
        logError "Failed to set PATH in user profile"
        return 1
    fi

    # Set ownership of home directory
    if ! chown "${LOCAL_USER_NAME}:${LOCAL_GROUP_NAME}" -R "${HOME_DIR}"; then
        logError "Failed to set ownership of home directory"
        return 1
    fi

    # Set ownership of current directory
    if ! chown "${LOCAL_USER_NAME}" "$PWD"; then
        logWarning "Failed to set ownership of current directory"
        # Not returning error as this might not be critical
    fi
}

# Execute command as user
executeAsUser() {
    logSuccess "Executing command as user ${LOCAL_USER_NAME}: $*"

    if ! su "${LOCAL_USER_NAME}" -s /bin/bash -c "$*"; then
        logError "Command execution failed"
        return 1
    fi
}

# Main function
main() {
    echo -e "\033[0;34m[+] Setting up the user environment\033[0m"

    # Set default values
    setDefaults

    # Setup user and group
    setupUserAndGroup

    # Setup user environment
    setupUserEnvironment || {
        logError "Failed to setup user environment"
        return 1
    }

    # Execute command as user
    if [ $# -eq 0 ]; then
        logError "No command specified"
        return 1
    fi

    executeAsUser "$*"
}

# Run the main function
main "$@"
