#!/usr/bin/env bash

# User entrypoint script for Webtrees
# This script creates a local user and group within the container based on environment variables,
# sets up the user's environment, and executes commands as that user.

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

# Displays a message when a task completes (job control).
set -m

IFS=$'\n\t'

# Logging utilities
log_success() {
    printf "\033[0;32m ✔\033[0m %s\n" "$1"
}

# Log a warning message to stderr with timestamp and color
log_warning() {
    printf "\033[0;33m ⚠\033[0m %s\n" "$1" >&2
}

log_error() {
    printf "\033[0;31m ✘\033[0m %s\n" "$1" >&2
}

# Set default values for environment variables
set_defaults() {
    if [ -z "${LOCAL_GROUP_NAME:-}" ]; then
        LOCAL_GROUP_NAME='www-data'
        log_success "Using default group name: ${LOCAL_GROUP_NAME}"
    fi

    if [ -z "${LOCAL_GROUP_ID:-}" ]; then
        LOCAL_GROUP_ID=82
        log_success "Using default group ID: ${LOCAL_GROUP_ID}"
    fi

    if [ -z "${LOCAL_USER_NAME:-}" ]; then
        LOCAL_USER_NAME=user
        log_success "Using default user name: ${LOCAL_USER_NAME}"
    fi

    if [ -z "${LOCAL_USER_ID:-}" ]; then
        LOCAL_USER_ID=1001
        log_success "Using default user ID: ${LOCAL_USER_ID}"
    fi

    # Set APP_BIN if APP_DIR is defined
    if [ -n "${APP_DIR:-}" ]; then
        APP_BIN="/var/www/html/app/vendor/bin"
        log_success "Setting up application binary directory to ${APP_BIN}"
    else
        APP_BIN=""
    fi

    # Set home directory and profile file
    if [ "${LOCAL_USER_ID}" -eq 0 ]; then
        LOCAL_USER_NAME="root"
        HOME_DIR="/root"
    else
        HOME_DIR="/home/${LOCAL_USER_NAME}"
    fi

    FILE_PROFILE="${HOME_DIR}/.bashrc"
}

# Create the user and group
setup_user_and_group() {
    log_success "Setting up user ${LOCAL_USER_NAME} (${LOCAL_USER_ID}) within group ${LOCAL_GROUP_NAME} (${LOCAL_GROUP_ID})"

    # Create the group (ignore errors if it already exists)
    if ! groupadd -r "${LOCAL_GROUP_NAME}" -g "${LOCAL_GROUP_ID}" >/dev/null 2>&1; then
        log_warning "Group ${LOCAL_GROUP_NAME} already exists or could not be created"
    fi

    # Create the user (ignore errors if it already exists)
    if ! useradd --no-log-init --create-home -u "${LOCAL_USER_ID}" -g "${LOCAL_GROUP_NAME}" \
        -s /bin/bash -d "${HOME_DIR}" "${LOCAL_USER_NAME}" >/dev/null 2>&1; then
        log_warning "User ${LOCAL_USER_NAME} already exists or could not be created"
    fi
}

# Setup the user's environment
setup_user_environment() {
    log_success "Setting up user environment in ${HOME_DIR}"

    # Copy mounted SSH files if they exist
    if [ -d /root/.ssh ]; then
        if [ "${HOME_DIR}" != "/root" ]; then
            if ! cp -r /root/.ssh "${HOME_DIR}"; then
                log_error "Failed to copy SSH files"
                return 1
            fi

            if ! chown "${LOCAL_USER_NAME}" -R "${HOME_DIR}"/.ssh; then
                log_error "Failed to set ownership of SSH files"
                return 1
            fi
        fi
    fi

    # Export all environment variables except HOME, otherwise the user would still have /root
    # as their home directory after running su.
    if ! export | grep -v HOME >>"${FILE_PROFILE}"; then
        log_error "Failed to export environment variables to user profile"
        return 1
    fi

    # Set working directory in user profile
    if ! printf "cd %s\n" "$PWD" >>"${FILE_PROFILE}"; then
        log_error "Failed to set working directory in user profile"
        return 1
    fi

    # Set PATH in user profile
    if ! printf "export PATH=\"%s/root/.composer/vendor/bin:\$HOME/.composer/vendor/bin:\$HOME/bin:\$PATH\"\n" "${APP_BIN:+$APP_BIN:}" >>"${FILE_PROFILE}"; then
        log_error "Failed to set PATH in user profile"
        return 1
    fi

    # Set ownership of home directory
    if ! chown "${LOCAL_USER_NAME}:${LOCAL_GROUP_NAME}" -R "${HOME_DIR}"; then
        log_error "Failed to set ownership of home directory"
        return 1
    fi

    # Set ownership of current directory
    if ! chown "${LOCAL_USER_NAME}" "$PWD"; then
        log_warning "Failed to set ownership of current directory"
        # Not returning error as this might not be critical
    fi
}

# Execute command as user
execute_as_user() {
    log_success "Executing command as user ${LOCAL_USER_NAME}: $*"

    if ! su "${LOCAL_USER_NAME}" -s /bin/bash -c "$*"; then
        log_error "Command execution failed"
        return 1
    fi
}

# Main function
main() {
    printf "\033[0;34m[+] Setting up the user environment\033[0m\n"

    # Set default values
    set_defaults

    # Setup user and group
    if [ "${LOCAL_USER_ID}" -ne 0 ]; then
        setup_user_and_group
    fi

    # Setup user environment
    if ! setup_user_environment; then
        log_error "Failed to setup user environment"
        return 1
    fi

    # Execute command as user
    if [ $# -eq 0 ]; then
        log_error "No command specified"
        return 1
    fi

    execute_as_user "$*"
}

# Run the main function
main "$@"
