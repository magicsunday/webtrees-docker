#!/usr/bin/env bash

# Root entrypoint script for Webtrees
# This script executes commands as root user

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Logging utilities
log_success() {
    printf "\033[0;32m ✔\033[0m %s\n" "$1"
}

log_error() {
    printf "\033[0;31m ✘\033[0m %s\n" "$1" >&2
}

# Main function
main() {
    if [[ $# -eq 0 ]]; then
        log_error "No command specified"
        return 1
    fi

    log_success "Executing command as root: $*"
    exec "$@"
}

# Run the main function
main "$@"
