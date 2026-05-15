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
# State machine, gated on the marker file /var/www/html/.webtrees-bundled-version
# and a sanity check that the bootstrap wrapper at /var/www/html/public/index.php
# exists. The marker MUST live inside the persistent volume so a container
# recreate doesn't trigger a re-seed against an already-populated volume:
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

    local marker="/var/www/html/.webtrees-bundled-version"
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

    log_success "Seeding /var/www/html from bundled webtrees ${bundled_version}"

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

# Headless bootstrap: when WT_ADMIN_USER is set, write config.ini.php,
# trigger DB schema migration, create the admin user, and grant admin role.
# Idempotent via /var/www/html/.webtrees-bootstrapped (marker lives inside the
# persistent volume so container recreate doesn't replay the admin-create step).
# Without WT_ADMIN_USER the function is a no-op and the browser-side setup
# wizard handles things.
#
# Inputs (env vars; *_FILE indirection already resolved by expand_file_secrets):
#   WT_ADMIN_USER          username for the admin account
#   WT_ADMIN_PASSWORD      password (typically from WT_ADMIN_PASSWORD_FILE)
#   WT_ADMIN_EMAIL         email (default: admin@example.org)
#   WT_ADMIN_REAL_NAME     real name (default: same as username)
#   MARIADB_HOST/PORT/USER/PASSWORD/DATABASE for the DB connection
#   WEBTREES_TABLE_PREFIX  table prefix (default: wt_)
#
# Schema migration: no CLI command exists; the canonical path is the HTTP
# UpdateDatabaseSchema middleware. We invoke MigrationService::updateSchema
# directly via php -r to avoid waiting for nginx + curl-with-https quirks.
setup_webtrees_bootstrap() {
    if [[ -z "${WT_ADMIN_USER:-}" ]]; then
        return 0
    fi

    if [[ -z "${WT_ADMIN_PASSWORD:-}" ]]; then
        log_error "WT_ADMIN_USER set but WT_ADMIN_PASSWORD is empty (forgot WT_ADMIN_PASSWORD_FILE?)"
        return 1
    fi

    local marker="/var/www/html/.webtrees-bootstrapped"
    local launcher="/var/www/html/public/index.php"

    if [[ -f "$marker" ]]; then
        return 0
    fi

    if [[ ! -f "$launcher" ]]; then
        log_error "Bootstrap requested but launcher missing at ${launcher} — webtrees not seeded yet"
        return 1
    fi

    # Pretty-URL toggle (rewrite_urls in config.ini.php). The webtrees
    # config-ini CLI accepts `--rewrite-urls` / `--no-rewrite-urls` as a
    # negatable option; when absent it defaults to the existing on-disk
    # value (or 0 on a fresh write). We only pass an explicit flag when
    # the operator has set WEBTREES_REWRITE_URLS — leaving the env var
    # unset keeps the core default behaviour.
    #
    # Encode the choice as a bare token (rewrite/norewrite/empty) here
    # rather than the literal `--rewrite-urls` / `--no-rewrite-urls`.
    # BusyBox `su` (Alpine, including arm64 builds) parses any positional
    # arg starting with `--` as one of its own options and aborts with
    # "su: unrecognized option: rewrite-urls" before exec'ing the inner
    # sh. Coreutils `su` on amd64 GHA runners doesn't share that quirk,
    # so the bug only surfaced on platforms running BusyBox su as the
    # default. The inner shell translates the token back to the literal
    # config-ini flag, so the on-disk behaviour stays identical.
    local rewrite_urls_token=""
    case "${WEBTREES_REWRITE_URLS:-}" in
        1|true|TRUE) rewrite_urls_token="rewrite" ;;
        0|false|FALSE) rewrite_urls_token="norewrite" ;;
    esac

    log_success "Writing config.ini.php via webtrees config-ini"
    # Values pass to the inner shell as positional args ($1..$8) rather
    # than being string-substituted into the -c body. A literal `'` or
    # any shell metacharacter in MARIADB_PASSWORD, table prefix, etc.
    # is therefore safe — the inner shell receives the value as a
    # discrete argv entry, not as part of the command source. The
    # outer `-c` body is single-quoted so $vars stay symbolic until
    # the inner shell expands them from its own argv. $rewrite_flag is
    # set inside the inner shell from the token $8 carries so empty
    # input drops the flag entirely.
    # shellcheck disable=SC2016  # inner shell expands $1..$8 from positional args
    if ! su www-data -s /bin/sh -c '
        case "$8" in
            rewrite)   rewrite_flag=--rewrite-urls ;;
            norewrite) rewrite_flag=--no-rewrite-urls ;;
            *)         rewrite_flag= ;;
        esac
        php "$1" config-ini \
            --dbtype=mysql \
            --dbhost="$2" \
            --dbport="$3" \
            --dbname="$4" \
            --dbuser="$5" \
            --dbpass="$6" \
            --tblpfx="$7" \
            $rewrite_flag
    ' webtrees-cli \
        "${launcher}" \
        "${MARIADB_HOST:-db}" \
        "${MARIADB_PORT:-3306}" \
        "${MARIADB_DATABASE:-webtrees}" \
        "${MARIADB_USER:-webtrees}" \
        "${MARIADB_PASSWORD}" \
        "${WEBTREES_TABLE_PREFIX:-wt_}" \
        "${rewrite_urls_token}"; then
        log_error "webtrees config-ini failed — marker not set, will retry on next start"
        return 1
    fi

    # The migration runs MigrationService::updateSchema(...) directly — the
    # same call the HTTP UpdateDatabaseSchema middleware makes on every request.
    # Order matters: Webtrees::bootstrap() wires the Registry container and
    # all factories; Console::bootstrap() then reads config.ini.php and opens
    # the DB connection. Without the Webtrees::bootstrap() prefix
    # Registry::container() throws "must not be accessed before initialization".
    # 60s upper bound + 5s SIGKILL grace: an empty-DB migration completes in
    # seconds, but PDO's default read timeout is unbounded — a network blip
    # would leave the entrypoint hanging until docker/orchestrator kills the
    # container. 60 covers PDO connect-warmup on a cold runner plus the
    # actual migration; -k 5 forces SIGKILL if SIGTERM does not propagate
    # through future su variants. busybox timeout exits 143 on SIGTERM /
    # 137 on SIGKILL; GNU timeout uses 124 — distinguish from real failure.
    log_success "Running webtrees DB schema migration"
    set +e
    timeout -k 5 60 su www-data -s /bin/sh -c '
        php -d display_errors=0 -r "
            require \"/var/www/html/vendor/autoload.php\";
            Fisharebest\\Webtrees\\Webtrees::new()->bootstrap();
            (new Fisharebest\\Webtrees\\Cli\\Console())->bootstrap();
            Fisharebest\\Webtrees\\Registry::container()
                ->get(Fisharebest\\Webtrees\\Services\\MigrationService::class)
                ->updateSchema(
                    \"\\\\Fisharebest\\\\Webtrees\\\\Schema\",
                    \"WT_SCHEMA_VERSION\",
                    Fisharebest\\Webtrees\\Webtrees::SCHEMA_VERSION
                );
            echo \"schema ok\n\";
        "
    '
    migration_rc=$?
    set -e
    case "$migration_rc" in
        0) ;;
        124|137|143)
            log_error "Webtrees DB schema migration timed out after 60s (exit $migration_rc)"
            return 1
            ;;
        *)
            log_error "Webtrees DB schema migration failed (exit $migration_rc)"
            return 1
            ;;
    esac

    # Idempotency: skip user-create if the user already exists.
    # Same positional-args pattern as config-ini above — values reach
    # the inner shell as $1 / $2 / $3, never substituted into the
    # command source, so a literal `'` or any metacharacter in
    # WT_ADMIN_USER / WT_ADMIN_REAL_NAME / WT_ADMIN_EMAIL /
    # WT_ADMIN_PASSWORD cannot escape the user-supplied-string context.
    # awk's `$1` field reference uses single quotes inside the body,
    # which is fine because the outer body is single-quoted at the
    # -c level (the inner shell strips its own quoting).
    # shellcheck disable=SC2016  # inner shell expands $1/$2 from positional args
    if su www-data -s /bin/sh -c '
        php "$1" user-list 2>/dev/null \
            | awk "NR>3 { print \$1 }" \
            | grep -qx "$2"
    ' webtrees-cli "${launcher}" "${WT_ADMIN_USER}"; then
        log_warn "User '${WT_ADMIN_USER}' already exists — skipping user-create"
    else
        log_success "Creating admin user: ${WT_ADMIN_USER}"
        # shellcheck disable=SC2016  # inner shell expands $1..$5 from positional args
        if ! su www-data -s /bin/sh -c '
            php "$1" user --create "$2" \
                --real-name="$3" \
                --email="$4" \
                --password="$5"
        ' webtrees-cli \
            "${launcher}" \
            "${WT_ADMIN_USER}" \
            "${WT_ADMIN_REAL_NAME:-${WT_ADMIN_USER}}" \
            "${WT_ADMIN_EMAIL:-admin@example.org}" \
            "${WT_ADMIN_PASSWORD}"; then
            log_error "user --create failed"
            return 1
        fi
    fi

    log_success "Granting admin role to: ${WT_ADMIN_USER}"
    # shellcheck disable=SC2016  # inner shell expands $1/$2 from positional args
    if ! su www-data -s /bin/sh -c '
        php "$1" user-setting "$2" canadmin 1
    ' webtrees-cli "${launcher}" "${WT_ADMIN_USER}"; then
        log_error "user-setting canadmin failed"
        return 1
    fi

    if ! touch "$marker"; then
        log_error "Cannot create marker ${marker} — bootstrap would re-run on every start"
        return 1
    fi
    chown www-data:www-data "$marker" 2>/dev/null || true

    log_success "Webtrees bootstrap complete"
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

# Render /etc/msmtprc from MAIL_* env vars (#67). The msmtp binary is
# wired as PHP's sendmail_path via /usr/local/etc/php/conf.d/webtrees-mail.ini
# so PHP's mail() / PHPMailer's sendmail transport reaches the operator's
# SMTP relay. Writing the file from scratch each boot keeps it idempotent
# — a restart with MAIL_SMTP changed produces the new value, not a stack
# of conflicting directives.
#
# When MAIL_SMTP transitions from set → unset between boots, the function
# REMOVES /etc/msmtprc so a stale config from the previous boot cannot
# silently keep routing mail through the old relay.
#
# webtrees' built-in SMTP transport (Control panel → Site settings →
# Email) bypasses msmtp entirely and remains the recommended path for
# auth'd / TLS relays.
#
# Input validation:
#   * MAIL_SMTP, MAIL_DOMAIN, MAIL_HOST values are written verbatim into
#     the rendered file. A newline / CR inside any of them would let an
#     operator-controlled value inject an extra msmtp directive (e.g. an
#     additional `host` line redirecting outbound mail). Reject any
#     value containing \n, \r, or other characters outside a safe set.
#   * MAIL_SMTP must split as host:port with a numeric port, or host
#     only (port defaults to 25). IPv6 literals are not supported via
#     this env-var path — operators with v6-only relays bind-mount
#     /etc/msmtprc directly.
setup_mail() {
    local config="/etc/msmtprc"

    if [ -z "${MAIL_SMTP:-}" ]; then
        # set → unset transition: drop the stale file. The `-f` ensures
        # we don't fail on a fresh container where the file never
        # existed.
        if [ -e "$config" ]; then
            rm -f "$config" || log_warn "Failed to remove stale ${config}"
        fi
        return 0
    fi

    # Reject newlines / CRs / tabs in any operator-supplied value before
    # they reach the heredoc. The literal-newline NL / CR vars dodge the
    # `$(printf '\n')` command-substitution trailing-newline-strip trap
    # (same pattern as the trust-proxy-extra script).
    local _NL
    _NL='
'
    local _CR _TAB
    _CR=$(printf '\r')
    _TAB=$(printf '\t')
    _setup_mail_reject_control() {
        case "$1" in
            *"$_NL"*|*"$_CR"*|*"$_TAB"*)
                log_error "MAIL_$2 contains control characters; refusing to render ${config}"
                return 1 ;;
        esac
        return 0
    }
    _setup_mail_reject_control "${MAIL_SMTP:-}"   "SMTP"   || return 1
    _setup_mail_reject_control "${MAIL_DOMAIN:-}" "DOMAIN" || return 1
    _setup_mail_reject_control "${MAIL_HOST:-}"   "HOST"   || return 1

    log_success "Setting up Mail configuration"

    # Pre-clear any stale .tmp from a crash mid-render on a prior boot.
    rm -f "${config}.tmp"

    # MAIL_SMTP is host[:port]. Split on the FIRST colon (not last —
    # bash %% would do greedy which mangles a port that contains digits
    # but is a no-op since ports are numeric anyway). A bare hostname
    # falls back to port 25.
    local host port
    host="${MAIL_SMTP%%:*}"
    if [ "${MAIL_SMTP}" = "${host}" ]; then
        port=25
    else
        port="${MAIL_SMTP#*:}"
    fi

    if [ -z "$host" ]; then
        log_error "MAIL_SMTP host part is empty; refusing to render ${config}"
        return 1
    fi
    case "$port" in
        ''|*[!0-9]*)
            log_error "MAIL_SMTP port '${port}' is not numeric; refusing to render ${config}"
            return 1 ;;
    esac

    # The `from` directive controls the envelope sender msmtp uses when
    # PHP didn't set one; MAIL_DOMAIN provides the right-hand side.
    # webtrees usually sets a real From: header in the message body so
    # this is a fallback for poorly-formed transactional mail.
    local from_line=""
    if [ -n "${MAIL_DOMAIN:-}" ]; then
        from_line="from               webtrees@${MAIL_DOMAIN}"
    fi

    # MAIL_HOST controls the HELO/EHLO identity sent to the relay. Many
    # relays reject EHLO from `localhost.localdomain` (msmtp's fallback
    # when MAIL_HOST is unset); operators with strict relays must set
    # MAIL_HOST to a forward-resolvable name.
    local domain_line=""
    if [ -n "${MAIL_HOST:-}" ]; then
        domain_line="domain             ${MAIL_HOST}"
    fi

    # Rewrite the file unconditionally — atomic via mv so a partial
    # write doesn't leave PHP's mail() trying to send through a half-
    # rendered config. `tls off` is the conservative default; operators
    # whose relay requires TLS bind-mount /etc/msmtprc with their own
    # STARTTLS / cert config.
    #
    # logfile /dev/stderr is critical for operability: Alpine doesn't
    # run a syslog daemon, so msmtp's default LOG_MAIL syslog target is
    # a black hole. Routing to /dev/stderr surfaces submission failures
    # in `docker logs` where the operator actually looks.
    if ! cat > "${config}.tmp" <<EOF
# Auto-rendered by docker-entrypoint.sh setup_mail() from MAIL_* env
# vars (#67). Do not bind-mount — overwritten on every container start.
# For STARTTLS / certificate-pinned relays, mount your own /etc/msmtprc.
defaults
auth               off
tls                off
logfile            /dev/stderr

account            default
host               ${host}
port               ${port}
${from_line}
${domain_line}
EOF
    then
        rm -f "${config}.tmp"
        log_error "Failed to render ${config}"
        return 1
    fi

    # chmod / chown BEFORE the swap so the file is never visible at the
    # wrong perms even briefly. www-data needs read access — PHP-FPM
    # workers run as www-data and exec msmtp as part of mail(); a
    # root-owned 0600 file would block them. Group-readable by www-data
    # only (mode 0640) protects against future password-in-config leaks
    # without breaking the current functional path.
    if ! chown root:www-data "${config}.tmp"; then
        rm -f "${config}.tmp"
        log_error "Failed to chown ${config}.tmp to root:www-data"
        return 1
    fi
    if ! chmod 0640 "${config}.tmp"; then
        rm -f "${config}.tmp"
        log_error "Failed to chmod 0640 ${config}.tmp"
        return 1
    fi

    if ! mv "${config}.tmp" "${config}"; then
        rm -f "${config}.tmp"
        log_error "Failed to swap ${config} into place"
        return 1
    fi

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

    # Remap www-data UID/GID to match host user (set by the installer wizard).
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

    # Opt-in headless bootstrap: writes config.ini.php + migrates DB schema +
    # creates admin user when WT_ADMIN_USER is set. No-op otherwise.
    if ! setup_webtrees_bootstrap; then
        log_error "Webtrees bootstrap failed — refusing to start"
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

    # Configure outbound mail. No-op when MAIL_SMTP is unset; otherwise
    # renders /etc/msmtprc so webtrees' transactional mail
    # (password-reset / contact-form / approval-pending notices) can
    # reach the operator-supplied relay via PHP's mail() (#67). Fail
    # fast on malformed MAIL_* input — a silent boot with a half-rendered
    # mail config produces opaque "password reset never arrived" reports
    # at 3am; a refused boot surfaces the misconfiguration immediately.
    if ! setup_mail; then
        log_error "Mail configuration failed — refusing to start"
        exit 1
    fi

    # Execute the main command
    exec "$@"
}

# Run the main function
main "$@"
