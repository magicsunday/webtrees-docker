#!/usr/bin/env bash

# Root entrypoint script for Webtrees
# This script executes commands as root user

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

# Treats unset or undefined variables as an error when substituting (during parameter expansion).
set -u

# Prevent masking an error in a pipeline
set -o pipefail

# Logging utilities
logSuccess() {
    echo -e "\033[0;32m ✔\033[0m $1"
}

logError() {
    echo -e "\033[0;31m ✘\033[0m $1" >&2
}

# Main function
main() {
    if [ $# -eq 0 ]; then
        logError "No command specified"
        return 1
    fi

    logSuccess "Executing command as root: $*"
    exec "$@"
}

# Run the main function
main "$@"
