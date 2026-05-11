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

log_warn() {
    printf "\033[0;33m ⚠\033[0m %s\n" "$1" >&2
}

# Check if a file exists and is writable
check_file_is_writable() {
    local file="$1"
    if [[ ! -w "$file" ]]; then
        return 1
    fi
    return 0
}

# Validate that a value matches an expected pattern
validate_php_value() {
    local name="$1"
    local value="$2"
    local pattern="$3"

    if [[ ! "$value" =~ $pattern ]]; then
        log_error "Invalid $name value: '$value'"
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
    if [ -z "${PHP_MAX_EXECUTION_TIME:-}" ]; then
        PHP_MAX_EXECUTION_TIME=30
    fi

    # Setup max_input_vars
    if [ -z "${PHP_MAX_INPUT_VARS:-}" ]; then
        PHP_MAX_INPUT_VARS=1000
    fi

    # Setup memory_limit
    if [ -z "${PHP_MEMORY_LIMIT:-}" ]; then
        PHP_MEMORY_LIMIT=128M
    fi

    # Validate PHP settings before applying
    validate_php_value "PHP_MAX_EXECUTION_TIME" "$PHP_MAX_EXECUTION_TIME" '^[0-9]+$' || return 1
    validate_php_value "PHP_MAX_INPUT_VARS" "$PHP_MAX_INPUT_VARS" '^[0-9]+$' || return 1
    validate_php_value "PHP_MEMORY_LIMIT" "$PHP_MEMORY_LIMIT" '^[0-9]+[KMGkmg]?$' || return 1

    if [ -n "${PHP_POST_MAX_SIZE:-}" ]; then
        validate_php_value "PHP_POST_MAX_SIZE" "$PHP_POST_MAX_SIZE" '^[0-9]+[KMGkmg]?$' || return 1
    fi

    if [ -n "${PHP_UPLOAD_MAX_FILESIZE:-}" ]; then
        validate_php_value "PHP_UPLOAD_MAX_FILESIZE" "$PHP_UPLOAD_MAX_FILESIZE" '^[0-9]+[KMGkmg]?$' || return 1
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
    if [ -n "${PHP_POST_MAX_SIZE:-}" ]; then
        sed -i "/^post_max_size =/s/=.*/= $PHP_POST_MAX_SIZE/" "$php_config_file" || {
            log_error "Failed to set post_max_size"
            return 1
        }
    fi

    # Setup upload_max_filesize if provided
    if [ -n "${PHP_UPLOAD_MAX_FILESIZE:-}" ]; then
        sed -i "/^upload_max_filesize =/s/=.*/= $PHP_UPLOAD_MAX_FILESIZE/" "$php_config_file" || {
            log_error "Failed to set upload_max_filesize"
            return 1
        }
    fi

    return 0
}

# Seed /var/www from the bundled webtrees release on first run.
#
# Opt-in via WEBTREES_AUTO_SEED=true (the base compose.yaml sets it; the dev
# overlay compose.development.yaml sets it to false so host bind-mounts of
# ./app are never touched).
#
# State machine, gated on the marker file /var/www/.webtrees-bundled-version
# and a sanity check that the bootstrap wrapper at /var/www/html/public/index.php
# exists:
#
#   marker absent + tree absent  → seed, then write marker
#   marker absent + tree present → refuse (pre-existing install, no version info)
#   marker present + matches     → verify tree intact, then skip
#   marker present + mismatch    → log warning (upgrade pending), skip
#   marker present + tree broken → fail fast (volume needs operator attention)
#
# Upgrades (WEBTREES_VERSION bump on the image) are NOT auto-applied: the
# function logs a warning and leaves the volume untouched so user data,
# installed modules and theme tweaks survive. Operator wipes the volume to
# re-seed.
setup_webtrees_dist() {
    if [[ "${WEBTREES_AUTO_SEED:-false}" != "true" ]]; then
        return 0
    fi

    if [[ -z "${WEBTREES_VERSION:-}" ]]; then
        log_error "WEBTREES_AUTO_SEED=true but WEBTREES_VERSION is empty — refusing to seed without a version identifier"
        return 1
    fi

    if [[ ! -d "/opt/webtrees-dist" ]]; then
        log_error "WEBTREES_AUTO_SEED=true but /opt/webtrees-dist is missing from the image"
        return 1
    fi

    local marker="/var/www/.webtrees-bundled-version"
    local bundled_version="$WEBTREES_VERSION"
    local front_controller="/var/www/html/public/index.php"

    if [[ -f "$marker" ]]; then
        local installed_version
        if ! installed_version=$(cat "$marker" 2>/dev/null); then
            log_error "Seed marker exists but cannot be read — volume may be corrupt"
            return 1
        fi
        if [[ -z "$installed_version" ]]; then
            log_error "Seed marker is empty — volume in inconsistent state"
            return 1
        fi

        if [[ "$installed_version" != "$bundled_version" ]]; then
            log_warn "Bundled webtrees ${bundled_version} differs from installed ${installed_version}. The on-disk vendor/ is the source of truth and is running with the patches it was seeded with — wipe the volume to seed the new image's vendor/ + patches."
        fi

        if [[ ! -f "$front_controller" ]]; then
            log_error "Marker says ${installed_version} but ${front_controller} is missing — volume needs operator attention"
            return 1
        fi

        return 0
    fi

    # No marker. If the volume already contains a webtrees install we don't
    # know about (e.g. seeded by an older image without marker support, or
    # installed manually), do not clobber it.
    if [[ -f "$front_controller" ]]; then
        log_warn "Volume holds an unmarked webtrees install — leaving it alone. Write ${marker} manually to silence this warning, or wipe the volume to re-seed."
        return 0
    fi

    log_success "Seeding /var/www from bundled webtrees ${bundled_version}"

    # Copy each top-level entry from the image into /var/www/html. We loop
    # rather than cp -a /opt/webtrees-dist/. /var/www/ wholesale so a
    # partial failure only rolls back what this run touched — a blanket
    # rm -rf /var/www/html would wipe a host bind-mount in dev.
    local entry
    for entry in /opt/webtrees-dist/html/*; do
        if ! cp -a "$entry" /var/www/html/; then
            log_error "Failed to copy $entry into /var/www/html — rolling back"
            rm -rf /var/www/html/composer.json /var/www/html/composer.lock \
                   /var/www/html/vendor /var/www/html/public /var/www/html/data
            return 1
        fi
    done

    # Hand ownership of the freshly-seeded tree to www-data so PHP-FPM can
    # write config.ini.php, cache and updates. chown -h leaves symlinks'
    # targets untouched (the vendor/.../data → ../../../data symlink).
    # The media bind-mount path is pruned so host UIDs there are preserved.
    if ! find /var/www/html -mindepth 1 \
            -path /var/www/html/data/media -prune -o \
            -exec chown -h www-data:www-data {} +; then
        log_error "chown of /var/www/html failed — refusing to mark seed complete"
        return 1
    fi

    # Marker written LAST and only after cp+chown both succeeded. An
    # interrupted or partially-failed seed leaves the marker absent, so the
    # next start retries cleanly.
    if ! echo "$bundled_version" > "$marker"; then
        log_error "Failed to write seed marker — wipe the volume to re-seed"
        # An empty or partial marker would hard-fail on the next start.
        # Remove it so the seed branch reruns instead.
        rm -f "$marker"
        return 1
    fi
    chown www-data:www-data "$marker" 2>/dev/null || true

    return 0
}

# Resolve any *_FILE env vars by reading their referenced file and exporting
# the corresponding non-_FILE variable. Standard Docker secret pattern from
# the official database images and the container-secret mount conventions:
#   MARIADB_PASSWORD_FILE=/run/secrets/db_password → MARIADB_PASSWORD=$(cat ...)
#
# References:
#   https://hub.docker.com/_/mariadb       (see "Docker Secrets" section)
#   https://hub.docker.com/_/mysql         ("As an alternative … _FILE may be appended")
#   https://hub.docker.com/_/postgres      (POSTGRES_PASSWORD_FILE)
#   https://docs.docker.com/engine/swarm/secrets/
#   https://kubernetes.io/docs/concepts/configuration/secret/
#
# After resolution the *_FILE variable is unset so downstream code sees the
# expanded value only.
#
# Two guards keep us from misinterpreting unrelated vars that happen to end
# in _FILE:
#   1. Hard skip-list (COMPOSE_FILE is a Docker Compose meta-var holding a
#      colon-separated chain of compose filenames, not a single path).
#   2. The value must look like an absolute path. Secret-mount paths from
#      Swarm/Kubernetes are always absolute (/run/secrets/…); a non-absolute
#      value indicates the variable is not following the secret-mount
#      convention and we leave it alone.
expand_file_secrets() {
    local var target_var file_path content
    while IFS= read -r var; do
        # Hard skip Docker/Compose meta-vars that legitimately end in _FILE.
        case "$var" in
            COMPOSE_FILE) continue ;;
        esac

        target_var="${var%_FILE}"
        file_path="$(printenv "$var" 2>/dev/null || true)"

        if [[ -z "$file_path" ]]; then
            continue
        fi

        # Only treat absolute paths as secret-mount references.
        if [[ "$file_path" != /* ]]; then
            continue
        fi

        if [[ ! -e "$file_path" ]]; then
            log_error "${var}=${file_path} but the file does not exist"
            return 1
        fi

        if [[ ! -r "$file_path" ]]; then
            log_error "${var}=${file_path} but the file is not readable"
            return 1
        fi

        # Strip a single trailing newline (common from `echo "secret" > file`)
        # but preserve embedded newlines in case the secret is multi-line.
        content="$(cat "$file_path")"
        export "${target_var}=${content}"
        unset "$var"
    done < <(env | awk -F= '$1 ~ /_FILE$/ {print $1}')

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
    if [[ -n "${ENFORCE_HTTPS:-}" ]] && [[ "${ENFORCE_HTTPS^^}" == "TRUE" ]]; then
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

    # Resolve any *_FILE secret references first so downstream env reads see
    # the expanded values (Docker Swarm / Kubernetes secret-mount pattern).
    if ! expand_file_secrets; then
        log_error "Failed to resolve *_FILE secret references — refusing to start"
        exit 1
    fi

    # Set default ENVIRONMENT if not provided
    if [[ -z "${ENVIRONMENT:-}" ]]; then
        ENVIRONMENT="production"
        log_success "No ENVIRONMENT specified, defaulting to production"
    fi

    # Remap www-data UID/GID to match host user (set by scripts/setup.sh).
    # Required on NAS systems where bind-mounted directories enforce host permissions.
    # Skip when user-entrypoint.sh follows (buildbox) to avoid UID collision.
    if [[ -n "${LOCAL_USER_ID:-}" ]] && [[ "${LOCAL_USER_ID}" != "0" ]] \
        && [[ "$(id -u www-data 2>/dev/null)" != "${LOCAL_USER_ID}" ]] \
        && [[ "${1:-}" != */user-entrypoint.sh ]]; then
        # Note: adduser/deluser flags are Alpine/BusyBox-specific.
        # If switching to a Debian-based image, replace with useradd/groupadd.
        deluser www-data 2>/dev/null || true
        delgroup www-data 2>/dev/null || true
        addgroup -g "${LOCAL_GROUP_ID:-82}" -S www-data 2>/dev/null || true
        adduser -u "${LOCAL_USER_ID}" -G www-data -s /sbin/nologin -D -H www-data 2>/dev/null || true

        if [[ "$(id -u www-data 2>/dev/null)" != "${LOCAL_USER_ID}" ]]; then
            log_error "Failed to remap www-data to UID ${LOCAL_USER_ID} — media uploads may fail"
        else
            sed -i "s/^user = .*/user = www-data/" /usr/local/etc/php-fpm.d/www.conf 2>/dev/null || true
            sed -i "s/^group = .*/group = www-data/" /usr/local/etc/php-fpm.d/www.conf 2>/dev/null || true
            log_success "Remapped www-data to UID:GID ${LOCAL_USER_ID}:${LOCAL_GROUP_ID:-82}"
        fi
    fi

    # Seed bundled webtrees into the app volume when configured to (production
    # mode, first run). Fail fast on copy errors so php-fpm does not start
    # against a broken tree.
    if ! setup_webtrees_dist; then
        log_error "Webtrees first-run initialisation failed — refusing to start"
        exit 1
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
