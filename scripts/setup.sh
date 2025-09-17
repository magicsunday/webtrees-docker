#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Global Variables
#
# SCRIPT_DIR: Directory where this script resides
# HOSTNAME: Current host name
# INTERACTIVE: Flag indicating whether the script runs interactively
# MISSING: Flag to track missing dependencies
# COMPOSE_BIN: Array holding Docker Compose command (v1 or v2)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname)
INTERACTIVE=0
MISSING=0
COMPOSE_BIN=()

# Default values for development environment
DEV_DOMAIN=${DEV_DOMAIN:-webtrees.nas.lan}
MARIADB_DATABASE=${MARIADB_DATABASE:-webtrees}
MARIADB_USER=${MARIADB_USER:-webtrees}
MARIADB_PASSWORD=${MARIADB_PASSWORD:-webtrees}
MARIADB_HOST=${MARIADB_HOST:-db}
MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD:-}
USE_TRAEFIK=0
USE_EXTERNAL_DB=0
USE_EXISTING_DB=0

# Print a success message in green with a check mark
log_success() {
    printf "\033[0;32m ✔\033[0m %s\n" "$1"
}

# Print a warning message in yellow with a warning symbol.
log_warning() {
    printf "\033[0;33m ⚠\033[0m %s\n" "$1" >&2
}

# Print an error message in red with a cross symbol.
log_error() {
    printf "\033[0;31m ✘\033[0m %s\n" "$1" >&2
}

# Returns 0 (true) if whiptail is available, 1 (false) otherwise
has_whiptail() {
    if command -v whiptail >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Yes/No prompt. Uses whiptail for a dialog when available; otherwise
# falls back to a plain terminal prompt. Returns 0 (success) for "Yes"
# and 1 for "No".
ask_yesno() {
    local prompt="$1"

    if has_whiptail; then
        whiptail --clear --yesno "$prompt" 10 60
    else
        local _in
        read -rp "$prompt [y/N]: " _in || _in=""
        case "${_in:-N}" in
            y|Y) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

# Generic text input prompt. Uses whiptail inputbox when available; otherwise
# reads from the terminal. Echoes the entered value (or the provided default
# if the user submits an empty value).
ask_input() {
    local prompt="$1" default="${2:-}"

    if has_whiptail; then
        whiptail --clear --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
    else
        local _in
        read -rp "$prompt${default:+ [$default]}: " _in || _in=""
        echo "${_in:-$default}"
    fi
}

# Verifies that a given command is available in PATH. If not found, marks the
# global MISSING flag so the script can abort gracefully later.
require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' not found in PATH."
        MISSING=1
    fi
}

# Determines which Docker Compose binary is available and configures the
# global COMPOSE_BIN array accordingly. Prefers `docker compose` (v2),
# falling back to `docker-compose` (v1). Returns 0 on success, 1 on failure.
resolve_compose_binary() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        COMPOSE_BIN=("docker" "compose")
        return 0
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_BIN=("docker-compose")
        return 0
    fi
    return 1
}

# Performs a light-weight check to see if the Docker daemon is reachable and
# warns the user if it is not. Does not fail the script to allow offline
# preparation of files.
check_docker() {
    if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
        log_warning "Docker daemon not reachable. Ensure Docker Desktop/daemon is running and you have permission to access it."
    fi
}

# Applies an in-place sed expression to a file. Supports both GNU and BSD sed
# by detecting availability and adjusting the -i syntax accordingly.
update_environment_file() {
    local expr="$1" file="$2"
    if sed --version >/dev/null 2>&1; then
        sed -i "$expr" "$file"
    else
        sed -i '' "$expr" "$file"
    fi
}

# Creates a directory if it does not exist. Emits a success message the first
# time a directory is created; remains silent if it already exists.
create_dir_if_missing() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log_success "Create directory: $dir"
        mkdir -p "$dir"
    fi
}

# Ensures a working .env exists in the project root. If none exists,
# copies .env.dist to .env. If .env is already present, warns and skips.
# Aborts if .env.dist is missing.
copy_env_file() {
    if [ -f ".env" ]; then
        log_warning "Environment file already exists. Copying will be skipped."
    elif [ -f ".env.dist" ]; then
        log_success "Copying .env.dist to .env"
        cp .env.dist .env
    else
        log_error "Environment file .env.dist does not exist. Aborting."
        exit 1
    fi
}

# Runs the interactive setup flow. Prompts the user (via whiptail if
# available) for key decisions and credentials, then stores results in
# global variables for later persistence into .env.
#
# Prompts include:
#   - Traefik reverse proxy availability (sets USE_TRAEFIK)
#   - DEV domain (defaults to current DEV_DOMAIN or SERVER_IP:APP_PORT)
#   - Whether to use an existing, initialized database (sets USE_EXISTING_DB)
#   - Whether to use an external database (sets USE_EXTERNAL_DB and MARIADB_HOST)
#   - MariaDB root password, database name, user, and user password
interactive_setup() {
    if ask_yesno "Is a Traefik reverse proxy available?"; then
        USE_TRAEFIK=1;
    else
        USE_TRAEFIK=0;
    fi

    if [ "$USE_TRAEFIK" -eq 1 ]; then
        DEFAULT_DEV_DOMAIN="${DEV_DOMAIN}"
    else
        APP_PORT_VALUE="$(sed -n 's/^APP_PORT=//p' .env | head -n1)"
        APP_PORT_VALUE=${APP_PORT_VALUE:-50010}

        PMA_PORT_VALUE="$(sed -n 's/^PMA_PORT=//p' .env | head -n1)"
        PMA_PORT_VALUE=${PMA_PORT_VALUE:-50011}

        SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

        if [ -z "$SERVER_IP" ]; then
            # Fallback methods for systems without hostname -I
            SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
        fi

        SERVER_IP=${SERVER_IP:-$HOSTNAME}

        APP_PORT_VALUE=$(ask_input "Enter host port for Webtrees (maps to container 80):" "${APP_PORT_VALUE}")
        PMA_PORT_VALUE=$(ask_input "Enter host port for phpMyAdmin (maps to container 80):" "${PMA_PORT_VALUE}")

        DEFAULT_DEV_DOMAIN="${SERVER_IP}:${APP_PORT_VALUE}"
    fi

    DEV_DOMAIN=$(ask_input "Enter the domain under which the DEV system should be accessible:" "$DEFAULT_DEV_DOMAIN")

    if ask_yesno "Do you want to use an existing database (already initialized)?"; then
        USE_EXISTING_DB=1;
    else
        USE_EXISTING_DB=0;
    fi

    if ask_yesno "Do you want to use an external database?"; then
        USE_EXTERNAL_DB=1;
    else
        USE_EXTERNAL_DB=0;
    fi

    if [ "$USE_EXTERNAL_DB" -eq 1 ]; then
        MARIADB_HOST=$(ask_input "Enter your external MySQL/MariaDB hostname or network:" "$MARIADB_HOST")
    else
        MARIADB_HOST=db
    fi

    MARIADB_ROOT_PASSWORD=$(ask_input "Enter your MySQL/MariaDB root password" "$MARIADB_ROOT_PASSWORD")
    MARIADB_DATABASE=$(ask_input "Enter your MySQL/MariaDB database name:" "$MARIADB_DATABASE")
    MARIADB_USER=$(ask_input "Enter your MySQL/MariaDB username:" "$MARIADB_USER")
    MARIADB_PASSWORD=$(ask_input "Enter your MySQL/MariaDB password" "$MARIADB_PASSWORD")
}

# Downloads the latest images referenced by the resolved compose files using
# the previously detected Docker Compose binary (v2 or v1). This is a thin
# wrapper to keep the main flow readable.
setup_compose_images() {
    "${COMPOSE_BIN[@]}" pull
}

# Prints post-setup guidance for the user. This function only outputs helpful
# information and does not modify any files or settings. It reminds the user to
# review important .env variables, file permissions for media, and how to apply
# configuration changes afterward.
post_setup_info() {
    if [ "${USE_TRAEFIK}" -eq 1 ]; then
        PMA_DOMAIN="pma-${DEV_DOMAIN}"
    else
        PMA_DOMAIN="${DEFAULT_DEV_DOMAIN%%:*}:${PMA_PORT_VALUE}"
    fi

    printf "\n"
    printf "\033[0;33m ⚠ Action required:\033[0m Please check your .env and set any missing values or update them according to your requirements, e.g."
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
    echo ""
    log_success "Access information:"
    echo ""
    echo "   - Webtrees: ${DEV_DOMAIN}"
    echo "   - phpMyAdmin: ${PMA_DOMAIN}"
    printf "\n"
    log_success "After you have reviewed and updated your .env as noted above, you can start the environment with 'make up'."
}

# Orchestrates the overall setup process:
#   1) Validates required tools and resolves Docker Compose binary
#   2) Ensures .env and required directories exist
#   3) Initializes compose file defaults and runs interactive prompts when in a TTY
#   4) Persists user choices and credentials into .env
#   5) Sets local user metadata
#   6) Pre-pulls Docker images to speed up first run
#   7) Ensures app directory exists and triggers 'make install'
#   8) Prints post-setup guidance without making further changes
main() {
    printf "Setting up webtrees docker environment\n\n"

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
        exit 1;
    fi

    check_docker

    printf "\033[0;34m[+] Setting up development environment\033[0m\n"

    cd "${SCRIPT_DIR}/.." || exit

    copy_env_file
    create_dir_if_missing "persistent/database"
    create_dir_if_missing "persistent/media"

    log_success "Setting up local development docker stack in COMPOSE_FILE"
    update_environment_file '/^[[:space:]]*COMPOSE_FILE=/s|COMPOSE_FILE=.*|COMPOSE_FILE=compose.yaml:compose.development.yaml|' .env

    if [ -t 0 ]; then
        INTERACTIVE=1;
    fi

    if [ "$INTERACTIVE" -eq 1 ]; then
        interactive_setup;
    fi

    # Update COMPOSE_FILE according to choices
    if [ "$USE_TRAEFIK" -eq 1 ]; then
        update_environment_file "s|^COMPOSE_FILE=.*|&:compose.traefik.yaml|" .env
    fi

    if [ "$USE_EXTERNAL_DB" -eq 1 ]; then
        update_environment_file "s|^COMPOSE_FILE=.*|&:compose.external.yaml|" .env
    fi

    # Enable development host port mappings only when NOT using a reverse proxy
    if [ "$USE_TRAEFIK" -eq 0 ]; then
        # Write APP_PORT and PMA_PORT to .env
        update_environment_file "s/^[#]*APP_PORT=.*/APP_PORT=${APP_PORT_VALUE}/" .env
        update_environment_file "s/^[#]*PMA_PORT=.*/PMA_PORT=${PMA_PORT_VALUE}/" .env

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
    update_environment_file "s/LOCAL_USER_NAME=.*/LOCAL_USER_NAME=$(whoami | sed 's/\./-/')/" .env

    setup_compose_images

    APP_DIR_VALUE=$(grep -E '^APP_DIR=' .env | sed 's/^APP_DIR=//')
    APP_DIR_VALUE=${APP_DIR_VALUE:-"./app"}
    create_dir_if_missing "$APP_DIR_VALUE"

    make install
    log_success "Development environment setup complete."

    post_setup_info
}

main "$@"
