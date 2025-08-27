#!/usr/bin/env bash

# Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -e

## Prints out command arguments during execution.
#set -x

source scripts/configuration

# Main execution
main() {
    echo -e "\033[0;34m[+] Re-apply webtrees configuration\033[0m"

    validateEnvironment
    setupConfiguration
    logSuccess "Configuration successfully applied"
}

main
