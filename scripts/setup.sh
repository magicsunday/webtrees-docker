#!/usr/bin/env bash

SCRIPT_DIR="$( realpath "$( dirname "${BASH_SOURCE[0]}" )" )"
HOSTNAME=$(hostname)

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
pattern="s/COMPOSE_FILE=.*/COMPOSE_FILE=docker-compose.yaml\:docker-compose.development.yaml\:docker-compose.traefik.yaml\:docker-compose.local.yaml/"
sed -i "${pattern}" .env

#read -rp "Enter the directory where your Webtrees installation is located: " APP_DIR
#pattern="s#APP_DIR=.*#APP_DIR=${APP_DIR}#"
#sed -i "${pattern}" .env

read -rp "Enter the domain under which the DEV system should be accessible [webtrees.nas.lan]: " DEV_DOMAIN
: ${DEV_DOMAIN:=webtrees.nas.lan}
pattern="s/DEV_DOMAIN=.*/DEV_DOMAIN=${DEV_DOMAIN}/"
sed -i "${pattern}" .env

read -rp "Enter your MySQL/MariaDB root password: " MARIADB_ROOT_PASSWORD
pattern="s/MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}/"
sed -i "${pattern}" .env

read -rp "Enter your MySQL/MariaDB hostname: " MARIADB_HOST
pattern="s/MARIADB_HOST=.*/MARIADB_HOST=${MARIADB_HOST}/"
sed -i "${pattern}" .env

read -rp "Enter your MySQL/MariaDB database name [webtrees]: " MARIADB_DATABASE
: ${MARIADB_DATABASE:=webtrees}
pattern="s/MARIADB_DATABASE=.*/MARIADB_DATABASE=${MARIADB_DATABASE}/"
sed -i "${pattern}" .env

read -rp "Enter your MySQL/MariaDB username [webtrees]: " MARIADB_USER
: ${MARIADB_USER:=webtrees}
pattern="s/MARIADB_USER=.*/MARIADB_USER=${MARIADB_USER}/"
sed -i "${pattern}" .env

read -rp "Enter your MySQL/MariaDB password [webtrees]: " MARIADB_PASSWORD
: ${MARIADB_PASSWORD:=webtrees}
pattern="s/MARIADB_PASSWORD=.*/MARIADB_PASSWORD=${MARIADB_PASSWORD}/"
sed -i "${pattern}" .env

echo "Set local user ID"
pattern="s/LOCAL_USER_ID=.*/LOCAL_USER_ID=$(id -u)/"
sed -i "${pattern}" .env

echo "Set local group ID"
pattern="s/LOCAL_GROUP_ID=.*/LOCAL_GROUP_ID=$(id -g)/"
sed -i "${pattern}" .env

echo "Set local username"
pattern="s/LOCAL_USER_NAME=.*/LOCAL_USER_NAME=$(whoami | sed 's/\./-/')/"
sed -i "${pattern}" .env

echo "Set GIT username"
pattern="s/GIT_AUTHOR_NAME=.*/GIT_AUTHOR_NAME=$(git config user.name)/"
sed -i "${pattern}" .env

echo "Set GIT email address"
pattern="s/GIT_AUTHOR_EMAIL=.*/GIT_AUTHOR_EMAIL=$(git config user.email)/"
sed -i "${pattern}" .env

echo "Run install"
bash -c "docker compose pull"
make install

echo "Development environment setup complete."
echo "You can now start the development environment with 'make up'"
