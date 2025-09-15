#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# shellcheck source=scripts/configuration
source scripts/configuration

# Main execution
main() {
    printf "\033[0;34m[+] Re-apply webtrees configuration\033[0m\n"

    validate_environment
    setup_configuration
    log_success "Configuration successfully applied"
}

main
