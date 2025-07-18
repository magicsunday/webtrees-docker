#!/usr/bin/env bash

# Docker entrypoint script for Webtrees
# This script configures the PHP environment and other settings before starting the main process

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

# Check if a file exists and is writable
checkFileIsWritable() {
    local file="$1"
    if [ ! -w "$file" ]; then
        return 1
    fi
    return 0
}

# Configure PHP settings based on environment variables
setupPHP() {
    local php_config_file="$PHP_INI_DIR/conf.d/webtrees-php.ini"

    logSuccess "Setting up PHP configuration"

    # Use the default PHP configuration depending on selected environment
    cp "$PHP_INI_DIR/php.ini-${ENVIRONMENT}" "$PHP_INI_DIR/php.ini" || {
        logError "Failed to copy PHP configuration file"
        return 1
    }

    # Setup max_execution_time
    if [ -z "$PHP_MAX_EXECUTION_TIME" ]; then
        PHP_MAX_EXECUTION_TIME=30
    fi

    # Setup max_input_vars
    if [ -z "$PHP_MAX_INPUT_VARS" ]; then
        PHP_MAX_INPUT_VARS=1000
    fi

    # Setup memory_limit
    if [ -z "$PHP_MEMORY_LIMIT" ]; then
        PHP_MEMORY_LIMIT=128M
    fi

    # Apply PHP settings
    sed -i "/^max_execution_time =/s/=.*/= $PHP_MAX_EXECUTION_TIME/" "$php_config_file" || {
        logError "Failed to set max_execution_time"
        return 1
    }

    sed -i "/^max_input_vars =/s/=.*/= $PHP_MAX_INPUT_VARS/" "$php_config_file" || {
        logError "Failed to set max_input_vars"
        return 1
    }

    sed -i "/^memory_limit =/s/=.*/= $PHP_MEMORY_LIMIT/" "$php_config_file" || {
        logError "Failed to set memory_limit"
        return 1
    }

    # Setup post_max_size if provided
    if [ -n "$PHP_POST_MAX_SIZE" ]; then
        sed -i "/^post_max_size =/s/=.*/= $PHP_POST_MAX_SIZE/" "$php_config_file" || {
            logError "Failed to set post_max_size"
            return 1
        }
    fi

    # Setup upload_max_filesize if provided
    if [ -n "$PHP_UPLOAD_MAX_FILESIZE" ]; then
        sed -i "/^upload_max_filesize =/s/=.*/= $PHP_UPLOAD_MAX_FILESIZE/" "$php_config_file" || {
            logError "Failed to set upload_max_filesize"
            return 1
        }
    fi

    return 0
}

# Configure environment-specific settings
setupEnvironment() {
    logSuccess "Setting up environment: $ENVIRONMENT"

    # Disable xdebug in production
    if [ "$ENVIRONMENT" == "production" ]; then
        if [ -f "$PHP_INI_DIR/conf.d/webtrees-xdebug.ini" ]; then
            mv "$PHP_INI_DIR/conf.d/webtrees-xdebug.ini" "$PHP_INI_DIR/conf.d/webtrees-xdebug.disabled" || {
                logError "Failed to disable XDEBUG in production"
                return 1
            }
            logSuccess "Disabled XDEBUG in production environment"
        fi
    fi

    # Configure HTTPS enforcement
    if [ -n "${ENFORCE_HTTPS:-}" ] && [ "${ENFORCE_HTTPS}" == "TRUE" ]; then
        logSuccess "HTTPS enforcement is enabled"
    else
        if [ -f "/etc/nginx/includes/enforce-https.conf" ]; then
            logSuccess "Disabling HTTPS enforcement"
            echo -n "" > /etc/nginx/includes/enforce-https.conf || {
                logError "Failed to disable HTTPS enforcement"
                return 1
            }
        fi
    fi

    return 0
}

# Configure mail settings
setupMail() {
    local mail_config_file="/etc/ssmtp/ssmtp.conf"

    # Skip if mail configuration is not needed or file doesn't exist
    if [ ! -f "$mail_config_file" ]; then
        return 0
    fi

    logSuccess "Setting up Mail configuration"

    # Configure SMTP server
    if [ -n "${MAIL_SMTP:-}" ]; then
        echo "mailhub = $MAIL_SMTP" >> "$mail_config_file" || {
            logError "Failed to configure SMTP server"
            return 1
        }
    fi

    # Configure mail domain
    if [ -n "${MAIL_DOMAIN:-}" ]; then
        echo "rewriteDomain = $MAIL_DOMAIN" >> "$mail_config_file" || {
            logError "Failed to configure mail domain"
            return 1
        }
    fi

    # Configure mail hostname
    if [ -n "${MAIL_HOST:-}" ]; then
        echo "hostname = $MAIL_HOST" >> "$mail_config_file" || {
            logError "Failed to configure mail hostname"
            return 1
        }
    fi

    # Allow overwriting FROM Header by PHP
    echo "FromLineOverride = YES" >> "$mail_config_file" || {
        logError "Failed to configure FromLineOverride"
        return 1
    }

    return 0
}

# Main function
main() {
    echo -e "\033[0;34m[+] Setting up NGINX, PHP and Mail configuration\033[0m"

    # Set default ENVIRONMENT if not provided
    if [ -z "${ENVIRONMENT:-}" ]; then
        ENVIRONMENT="production"

        logSuccess "No ENVIRONMENT specified, defaulting to production"
    fi

    # Check if we have write permissions to PHP configuration directories
    if ! checkFileIsWritable "$PHP_INI_DIR/conf.d"; then
        logError "No write permission to PHP configuration directory. Skipping PHP configuration."
        exec "$@"
        return 0
    fi

    # Configure the environment
    setupEnvironment || logError "Environment configuration failed"

    # Configure PHP settings
    setupPHP || logError "PHP configuration failed"

# TODO
#    # Configure mail settings
#    setupMail || logError "Mail configuration failed"

    # Execute the main command
    exec "$@"
}

# Run the main function
main "$@"
