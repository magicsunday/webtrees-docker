#!/usr/bin/env bash

# Portable script dir detection (no dependency on realpath)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname)

# Prerequisite checks and helpers
set -euo pipefail

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
            echo "docker compose"
            return 0
        fi
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
        return 0
    fi
    echo ""; return 1
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

COMPOSE_BIN="$(resolve_compose_binary || true)"
if [[ -z "${COMPOSE_BIN}" ]]; then
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

echo "Setting up development environment"

cd "${SCRIPT_DIR}/.." || exit

if [ -f ".env" ]; then
    echo "Environment file already exists. Skipping."
    exit 0;
fi

if [ ! -f ".env.dist" ]; then
    echo "Environment file .env.dist does not exist. Aborting."
    exit 1;
fi

echo "Copying .env.dist to .env"
cp .env.dist .env

if [ ! -d "persistent/database" ]; then
    echo "Create database directory"
    mkdir -p "persistent/database"
fi

if [ ! -d "persistent/media" ]; then
    echo "Create media directory"
    mkdir -p "persistent/media"
fi

echo "Setup local development docker stack in COMPOSE_FILE"
pattern='/^[[:space:]]*COMPOSE_FILE=/s|COMPOSE_FILE=.*|COMPOSE_FILE=compose.yaml:compose.development.yaml:compose.traefik.yaml:compose.external-db.yaml|'
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

if [ "$INTERACTIVE" -eq 1 ]; then
    read -rp "Enter the domain under which the DEV system should be accessible [${DEV_DOMAIN}]: " _in || true
    DEV_DOMAIN=${_in:-$DEV_DOMAIN}

    read -rp "Enter your MySQL/MariaDB root password: " _in || true
    MARIADB_ROOT_PASSWORD=${_in:-$MARIADB_ROOT_PASSWORD}

    read -rp "Enter your MySQL/MariaDB hostname [${MARIADB_HOST}]: " _in || true
    MARIADB_HOST=${_in:-$MARIADB_HOST}

    read -rp "Enter your MySQL/MariaDB database name [${MARIADB_DATABASE}]: " _in || true
    MARIADB_DATABASE=${_in:-$MARIADB_DATABASE}

    read -rp "Enter your MySQL/MariaDB username [${MARIADB_USER}]: " _in || true
    MARIADB_USER=${_in:-$MARIADB_USER}

    read -rp "Enter your MySQL/MariaDB password [${MARIADB_PASSWORD}]: " _in || true
    MARIADB_PASSWORD=${_in:-$MARIADB_PASSWORD}
fi

update_environment_file "s/DEV_DOMAIN=.*/DEV_DOMAIN=${DEV_DOMAIN}/" .env
update_environment_file "s/MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}/" .env
update_environment_file "s/MARIADB_HOST=.*/MARIADB_HOST=${MARIADB_HOST}/" .env
update_environment_file "s/MARIADB_DATABASE=.*/MARIADB_DATABASE=${MARIADB_DATABASE}/" .env
update_environment_file "s/MARIADB_USER=.*/MARIADB_USER=${MARIADB_USER}/" .env
update_environment_file "s/MARIADB_PASSWORD=.*/MARIADB_PASSWORD=${MARIADB_PASSWORD}/" .env

echo "Set local user ID"
update_environment_file "s/LOCAL_USER_ID=.*/LOCAL_USER_ID=$(id -u)/" .env

echo "Set local group ID"
update_environment_file "s/LOCAL_GROUP_ID=.*/LOCAL_GROUP_ID=$(id -g)/" .env

echo "Set local username"
# Ensure username contains only allowed chars (replace dots with dashes)
update_environment_file "s/LOCAL_USER_NAME=.*/LOCAL_USER_NAME=$(whoami | sed 's/\./-/')/" .env

# Git identity
GIT_NAME=$(git config user.name || true)
GIT_EMAIL=$(git config user.email || true)
if [ -z "${GIT_NAME}" ]; then GIT_NAME="webtrees-developer"; fi
if [ -z "${GIT_EMAIL}" ]; then GIT_EMAIL="developer@example.com"; fi

echo "Set GIT username"
update_environment_file "s/GIT_AUTHOR_NAME=.*/GIT_AUTHOR_NAME=${GIT_NAME}/" .env

echo "Set GIT email address"
update_environment_file "s/GIT_AUTHOR_EMAIL=.*/GIT_AUTHOR_EMAIL=${GIT_EMAIL}/" .env

echo "Run install"

# Pull images using detected compose binary (v2 or v1)
$COMPOSE_BIN pull

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
log_success "You can now start the development environment with 'make up'"
