#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Portable script dir detection (no dependency on realpath)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname)

# Logging utilities
log_success() {
    printf "\033[0;32m ✔\033[0m %s\n" "$1"
}

log_warning() {
    printf "\033[0;33m ⚠\033[0m %s\n" "$1" >&2
}

log_error() {
    printf "\033[0;31m ✘\033[0m %s\n" "$1" >&2
}

MISSING=0
require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' not found in PATH."
        MISSING=1
    fi
}

# Detect Docker Compose binary (v2 plugin or v1)
resolve_compose_binary() {
    if command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            COMPOSE_BIN=("docker" "compose")
            return 0
        fi
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_BIN=("docker-compose")
        return 0
    fi
    return 1
}

# sed wrapper that applies sed -i edits portably on GNU and BSD/macOS systems.
update_environment_file() {
    local expr="$1" file="$2"
    if sed --version >/dev/null 2>&1; then
        sed -i "$expr" "$file"
    else
        sed -i '' "$expr" "$file"
    fi
}

printf "Setting up webtrees docker environment\n"
printf "\n"

# Basic prerequisites
require_command bash
require_command sed
require_command git
require_command make
require_command docker || true

resolve_compose_binary || true
if [[ -z "${COMPOSE_BIN[*]}" ]]; then
    log_error "Docker Compose is not available. Please install Docker Desktop (includes docker compose) or docker-compose."
    MISSING=1
fi

if [ "$MISSING" -ne 0 ]; then
    log_error "One or more required tools are missing. Please install the missing prerequisites and re-run scripts/setup.sh."
    exit 1
fi

# Verify Docker daemon is reachable (non-fatal but informative)
if command -v docker >/dev/null 2>&1; then
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker daemon not reachable. Ensure Docker Desktop/daemon is running and you have permission to access it."
    fi
fi

printf "\033[0;34m[+] Setting up development environment\033[0m\n"

cd "${SCRIPT_DIR}/.." || exit

if [ -f ".env" ]; then
    log_warning "Environment file already exists. Skipping."
    exit 0;
fi

if [ ! -f ".env.dist" ]; then
    log_error "Environment file .env.dist does not exist. Aborting."
    exit 1;
fi

log_success "Copying .env.dist to .env"
cp .env.dist .env

if [ ! -d "persistent/database" ]; then
    log_success "Create database directory"
    mkdir -p "persistent/database"
fi

if [ ! -d "persistent/media" ]; then
    log_success "Create media directory"
    mkdir -p "persistent/media"
fi

log_success "Setting up local development docker stack in COMPOSE_FILE"
# Set a minimal default compose stack; additional files can be added interactively
pattern='/^[[:space:]]*COMPOSE_FILE=/s|COMPOSE_FILE=.*|COMPOSE_FILE=compose.yaml:compose.development.yaml|'
update_environment_file "${pattern}" .env

# Interactive detection
INTERACTIVE=0
if [ -t 0 ]; then
    INTERACTIVE=1;
fi

# Defaults
DEV_DOMAIN=${DEV_DOMAIN:-webtrees.nas.lan}
MARIADB_DATABASE=${MARIADB_DATABASE:-webtrees}
MARIADB_USER=${MARIADB_USER:-webtrees}
MARIADB_PASSWORD=${MARIADB_PASSWORD:-webtrees}
MARIADB_HOST=${MARIADB_HOST:-db}
MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD:-}

USE_TRAEFIK=0
USE_EXTERNAL_DB=0

if [ "$INTERACTIVE" -eq 1 ]; then
    printf "\033[0;34m[+] Interactive setup\033[0m\n"

    # Ask whether Traefik is available as reverse proxy FIRST
    read -rp "Is a Traefik reverse proxy available? [y/N]: " _in || true

    case "${_in:-N}" in
        y|Y) USE_TRAEFIK=1 ;;
        *) USE_TRAEFIK=0 ;;
    esac

    # Determine a sensible default for DEV_DOMAIN based on proxy choice
    if [ "$USE_TRAEFIK" -eq 1 ]; then
        # Keep the current/default value (e.g., webtrees.nas.lan) when using a reverse proxy
        DEFAULT_DEV_DOMAIN="${DEV_DOMAIN}"
    else
        # No reverse proxy: determine APP_PORT and use detected server IP as the default
        # Safely read APP_PORT from .env (sed returns 0 even if no match)
        APP_PORT_VALUE="$(sed -n 's/^APP_PORT=//p' .env | head -n1)"
        if [ -z "${APP_PORT_VALUE:-}" ]; then
            APP_PORT_VALUE=50010
        fi

        SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

        if [ -z "$SERVER_IP" ]; then
            # Fallback methods for systems without hostname -I
            SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
        fi

        if [ -z "$SERVER_IP" ]; then
            SERVER_IP=${HOSTNAME}
        fi

        DEFAULT_DEV_DOMAIN="${SERVER_IP}:${APP_PORT_VALUE}"
    fi

    # Ask for DEV_DOMAIN once, using the computed default
    read -rp "Enter the domain under which the DEV system should be accessible [${DEFAULT_DEV_DOMAIN}]: " _in || true
    DEV_DOMAIN=${_in:-$DEFAULT_DEV_DOMAIN}

    # Ask whether to use an existing database or not
    read -rp "Do you want to use an existing database (already initialized)? [y/N]: " _in || true
    case "${_in:-N}" in
        y|Y) USE_EXISTING_DB=1 ;;
        *) USE_EXISTING_DB=0 ;;
    esac

    # Ask whether to use a local or an external database
    read -rp "Do you want to use an external database? [y/N]: " _in || true
    case "${_in:-N}" in
        y|Y) USE_EXTERNAL_DB=1 ;;
        *) USE_EXTERNAL_DB=0 ;;
    esac

    read -rp "Enter your MySQL/MariaDB root password: " _in || true
    MARIADB_ROOT_PASSWORD=${_in:-$MARIADB_ROOT_PASSWORD}

    if [ "$USE_EXTERNAL_DB" -eq 1 ]; then
        # When using an external DB, ask for the hostname/network name
        read -rp "Enter your external MySQL/MariaDB hostname or network [${MARIADB_HOST}]: " _in || true
        MARIADB_HOST=${_in:-$MARIADB_HOST}
    else
        # For local DB, enforce built-in service name
        MARIADB_HOST=db
    fi

    read -rp "Enter your MySQL/MariaDB database name [${MARIADB_DATABASE}]: " _in || true
    MARIADB_DATABASE=${_in:-$MARIADB_DATABASE}

    read -rp "Enter your MySQL/MariaDB username [${MARIADB_USER}]: " _in || true
    MARIADB_USER=${_in:-$MARIADB_USER}

    read -rp "Enter your MySQL/MariaDB password [${MARIADB_PASSWORD}]: " _in || true
    MARIADB_PASSWORD=${_in:-$MARIADB_PASSWORD}
fi

printf "\033[0;34m[+] Updating environment file\033[0m\n"

# Update COMPOSE_FILE according to choices
if [ "$USE_TRAEFIK" -eq 1 ]; then
    update_environment_file "s|^COMPOSE_FILE=.*|&:compose.traefik.yaml|" .env
fi

if [ "$USE_EXTERNAL_DB" -eq 1 ]; then
    update_environment_file "s|^COMPOSE_FILE=.*|&:compose.external.yaml|" .env
fi

# Enable development host port mappings only when NOT using a reverse proxy
if [ "$USE_TRAEFIK" -eq 0 ]; then
    # Uncomment or create APP_PORT and PMA_PORT with defaults
    update_environment_file "s/^[#]*APP_PORT=.*/APP_PORT=50010/" .env
    update_environment_file "s/^[#]*PMA_PORT=.*/PMA_PORT=50011/" .env

    # When no reverse proxy is used, do not enforce HTTPS inside nginx/app
    update_environment_file "s/^[#]*ENFORCE_HTTPS=.*/ENFORCE_HTTPS=FALSE/" .env
fi

update_environment_file "s/DEV_DOMAIN=.*/DEV_DOMAIN=${DEV_DOMAIN}/" .env
update_environment_file "s/MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}/" .env
update_environment_file "s/MARIADB_HOST=.*/MARIADB_HOST=${MARIADB_HOST}/" .env
update_environment_file "s/MARIADB_DATABASE=.*/MARIADB_DATABASE=${MARIADB_DATABASE}/" .env
update_environment_file "s/MARIADB_USER=.*/MARIADB_USER=${MARIADB_USER}/" .env
update_environment_file "s/MARIADB_PASSWORD=.*/MARIADB_PASSWORD=${MARIADB_PASSWORD}/" .env

# Persist choice about existing database usage (default to 1 if absent later)
if [ -n "${USE_EXISTING_DB:-}" ]; then
    update_environment_file "s/^[#]*USE_EXISTING_DB=.*/USE_EXISTING_DB=${USE_EXISTING_DB}/" .env
fi

log_success "Set local user ID"
update_environment_file "s/LOCAL_USER_ID=.*/LOCAL_USER_ID=$(id -u)/" .env

#echo "Set local group ID"
#update_environment_file "s/LOCAL_GROUP_ID=.*/LOCAL_GROUP_ID=$(id -g)/" .env

log_success "Set local username"
# Ensure username contains only allowed chars (replace dots with dashes)
update_environment_file "s/LOCAL_USER_NAME=.*/LOCAL_USER_NAME=$(whoami | sed 's/\./-/')/" .env

# Git identity
GIT_NAME=$(git config user.name || true)
GIT_EMAIL=$(git config user.email || true)
if [ -z "${GIT_NAME}" ]; then GIT_NAME="webtrees-developer"; fi
if [ -z "${GIT_EMAIL}" ]; then GIT_EMAIL="developer@example.com"; fi

log_success "Set GIT username"
update_environment_file "s/GIT_AUTHOR_NAME=.*/GIT_AUTHOR_NAME=${GIT_NAME}/" .env

log_success "Set GIT email address"
update_environment_file "s/GIT_AUTHOR_EMAIL=.*/GIT_AUTHOR_EMAIL=${GIT_EMAIL}/" .env

# Pull images using detected compose binary (v2 or v1)
"${COMPOSE_BIN[@]}" pull

# Ensure APP_DIR exists before installation
# Read APP_DIR from .env; default to ./app if unset
APP_DIR_VALUE=$(grep -E '^APP_DIR=' .env | sed 's/^APP_DIR=//')
if [ -z "${APP_DIR_VALUE:-}" ]; then
    APP_DIR_VALUE="./app"
fi

# Create directory if it does not exist (relative to project root)
if [ ! -d "$APP_DIR_VALUE" ]; then
    echo "Create application directory: $APP_DIR_VALUE"
    mkdir -p "$APP_DIR_VALUE"
fi

make install

log_success "Development environment setup complete."

# Post-setup information (no changes are performed here)
printf "\n"
log_warning "Action required: Please check your .env and set any missing values or update them according to your requirements, e.g."
echo ""
echo "   - LOCAL_GROUP_ID and LOCAL_GROUP_NAME"
echo "   - MEDIA_DIR"
echo "   - WEBTREES_TABLE_PREFIX"
echo "   - WEBTREES_REWRITE_URLS"
echo ""
echo "   Reminder: The media directory must be writable by the LOCAL_GROUP_ID inside the container."
echo "             If the container group differs from the host, you might need to set folder rights to 777 on the media directory."
echo ""
echo "   Note: If you change the database configuration, DEV_DOMAIN, or any WEBTREES_* variables in your .env later,"
echo "         run 'make apply-config' to re-apply the configuration to the application."
printf "\n"

log_success "After you have reviewed and updated your .env as noted above, you can start the environment with 'make up'."
