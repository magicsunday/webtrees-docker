#!/usr/bin/env bash

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

## Prints out command arguments during execution.
#set -x

source scripts/configuration

# Create directories before mounting
DIRS=(
    "${APP_DIR}"
    "./setup"
    "$APP_DIR/public"
    "$APP_DIR/vendor"
)

echo -e "\033[0;34m[+] Change permissions for APP_DIR: ${APP_DIR}\033[0m"

# Create directories with proper permissions
for dir in "${DIRS[@]}"; do
    if [[ ! "$dir" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        logError "Invalid directory name: $dir"
        exit 1
    fi

    mkdir -p "$dir" || {
        logError "Failed to create directory: $dir"
        exit 1
    }
done

# Validate and set ownership
if validateIds "${LOCAL_USER_ID}" "${LOCAL_GROUP_ID}"; then
    USER="${LOCAL_USER_ID}"
    GROUP="${LOCAL_GROUP_ID}"

    # Quote the array expansion properly
    chown -R "${USER}:${GROUP}" "${DIRS[@]}" || {
        logError "Failed to change ownership"
        exit 1
    }
    chmod -R ug+rw "${DIRS[@]}" || {
        logError "Failed to change permissions"
        exit 1
    }
else
    exit 1
fi

rm -rf "$APP_DIR/html"

# Copy public folder to webtrees directory
ln -s public "$APP_DIR/html"

logSuccess "Permissions changed successfully"
