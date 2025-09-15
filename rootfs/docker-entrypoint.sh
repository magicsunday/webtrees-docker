#!/usr/bin/env bash

# Docker entrypoint script for Webtrees
# This script configures the PHP environment and other settings before starting the main process

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

# Check if a file exists and is writable
check_file_is_writable() {
    local file="$1"
    if [[ ! -w "$file" ]]; then
        return 1
    fi
    return 0
}

# Configure PHP settings based on environment variables
setup_php() {
    local php_config_file="$PHP_INI_DIR/conf.d/webtrees-php.ini"

    log_success "Setting up PHP configuration"

    # Use the default PHP configuration depending on selected environment
    cp "$PHP_INI_DIR/php.ini-${ENVIRONMENT}" "$PHP_INI_DIR/php.ini" || {
        log_error "Failed to copy PHP configuration file"
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
        log_error "Failed to set max_execution_time"
        return 1
    }

    sed -i "/^max_input_vars =/s/=.*/= $PHP_MAX_INPUT_VARS/" "$php_config_file" || {
        log_error "Failed to set max_input_vars"
        return 1
    }

    sed -i "/^memory_limit =/s/=.*/= $PHP_MEMORY_LIMIT/" "$php_config_file" || {
        log_error "Failed to set memory_limit"
        return 1
    }

    # Setup post_max_size if provided
    if [ -n "$PHP_POST_MAX_SIZE" ]; then
        sed -i "/^post_max_size =/s/=.*/= $PHP_POST_MAX_SIZE/" "$php_config_file" || {
            log_error "Failed to set post_max_size"
            return 1
        }
    fi

    # Setup upload_max_filesize if provided
    if [ -n "$PHP_UPLOAD_MAX_FILESIZE" ]; then
        sed -i "/^upload_max_filesize =/s/=.*/= $PHP_UPLOAD_MAX_FILESIZE/" "$php_config_file" || {
            log_error "Failed to set upload_max_filesize"
            return 1
        }
    fi

    return 0
}

# Configure environment-specific settings
setup_environment() {
    log_success "Setting up environment: ${ENVIRONMENT}"

    # Disable xdebug in production
    if [[ "${ENVIRONMENT}" == "production" ]]; then
        if [[ -f "$PHP_INI_DIR/conf.d/webtrees-xdebug.ini" ]]; then
            mv "$PHP_INI_DIR/conf.d/webtrees-xdebug.ini" "$PHP_INI_DIR/conf.d/webtrees-xdebug.disabled" || {
                log_error "Failed to disable XDEBUG in production"
                return 1
            }
            log_success "Disabled XDEBUG in production environment"
        fi
    fi

    # Configure HTTPS enforcement
    if [[ -n "${ENFORCE_HTTPS:-}" ]] && [[ "${ENFORCE_HTTPS}" == "TRUE" ]]; then
        log_success "HTTPS enforcement is enabled"
    else
        if [[ -f "/etc/nginx/includes/enforce-https.conf" ]]; then
            log_success "Disabling HTTPS enforcement"
            : > /etc/nginx/includes/enforce-https.conf || {
                log_error "Failed to disable HTTPS enforcement"
                return 1
            }
        fi
    fi

    return 0
}

# Configure mail settings
setup_mail() {
    local mail_config_file="/etc/ssmtp/ssmtp.conf"

    # Skip if mail configuration is not needed or file doesn't exist
    if [ ! -f "$mail_config_file" ]; then
        return 0
    fi

    log_success "Setting up Mail configuration"

    # Configure SMTP server
    if [ -n "${MAIL_SMTP:-}" ]; then
        echo "mailhub = $MAIL_SMTP" >> "$mail_config_file" || {
            log_error "Failed to configure SMTP server"
            return 1
        }
    fi

    # Configure mail domain
    if [ -n "${MAIL_DOMAIN:-}" ]; then
        echo "rewriteDomain = $MAIL_DOMAIN" >> "$mail_config_file" || {
            log_error "Failed to configure mail domain"
            return 1
        }
    fi

    # Configure mail hostname
    if [ -n "${MAIL_HOST:-}" ]; then
        echo "hostname = $MAIL_HOST" >> "$mail_config_file" || {
            log_error "Failed to configure mail hostname"
            return 1
        }
    fi

    # Allow overwriting FROM Header by PHP
    echo "FromLineOverride = YES" >> "$mail_config_file" || {
        log_error "Failed to configure FromLineOverride"
        return 1
    }

    return 0
}

# Main function
main() {
    printf "\033[0;34m[+] Setting up NGINX, PHP and Mail configuration\033[0m\n"

    # Set default ENVIRONMENT if not provided
    if [[ -z "${ENVIRONMENT:-}" ]]; then
        ENVIRONMENT="production"
        log_success "No ENVIRONMENT specified, defaulting to production"
    fi

    # Check if we have write permissions to PHP configuration directories
    if ! check_file_is_writable "$PHP_INI_DIR/conf.d"; then
        log_error "No write permission to PHP configuration directory. Skipping PHP configuration."
        exec "$@"
        return 0
    fi

    # Configure the environment
    setup_environment || log_error "Environment configuration failed"

    # Configure PHP settings
    setup_php || log_error "PHP configuration failed"

# TODO
#    # Configure mail settings
#    setup_mail || log_error "Mail configuration failed"

    # Execute the main command
    exec "$@"
}

# Run the main function
main "$@"
