#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# shellcheck source=scripts/configuration
source scripts/configuration

# Create directories before mounting
DIRS=(
    "${APP_DIR}"
    "./setup"
    "${APP_DIR}/public"
    "${APP_DIR}/vendor"
)

printf "\033[0;34m[+] Change permissions for APP_DIR: %s\033[0m\n" "${APP_DIR}"

# Create directories with proper permissions
for dir in "${DIRS[@]}"; do
    if [[ ! "${dir}" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        log_error "Invalid directory name: ${dir}"
        exit 1
    fi

    mkdir -p "${dir}" || {
        log_error "Failed to create directory: ${dir}"
        exit 1
    }
done

# Validate and set ownership
if validate_ids "${LOCAL_USER_ID}" "${LOCAL_GROUP_ID}"; then
    user="${LOCAL_USER_ID}"
    group="${LOCAL_GROUP_ID}"

    # Quote the array expansion properly
    chown -R "${user}:${group}" "${DIRS[@]}" || {
        log_error "Failed to change ownership"
        exit 1
    }
    chmod -R ug+rw "${DIRS[@]}" || {
        log_error "Failed to change permissions"
        exit 1
    }
else
    exit 1
fi

rm -rf "${APP_DIR}/html"

# Copy public folder to webtrees directory
ln -s public "${APP_DIR}/html"

log_success "Permissions changed successfully"
