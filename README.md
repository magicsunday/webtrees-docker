# 🚀 Webtrees Docker

A Docker-based environment for running and developing [Webtrees](https://www.webtrees.net/), the free and open source web genealogy application.

This repository serves two audiences:

- **Self-hosters** who want a running webtrees instance → pull the pre-built image from ghcr.io and run with one compose chain
- **Module developers** who hack on webtrees modules → clone the repo, bind-mount the source, and use the buildbox

## 📚 Table of Contents

- [Self-host Quickstart](#-self-host-quickstart)
- [Module Developer Quickstart](#-module-developer-quickstart)
- [Requirements](#-requirements)
- [Installing Modules (self-host)](#-installing-modules-self-host)
- [Switching Between Dev and Production Mode](#-switching-between-dev-and-production-mode)
- [Setup and Installation](#️-setup-and-installation)
    - [Clone the Repository](#-clone-the-repository)
    - [Run the Setup Script](#️-run-the-setup-script)
    - [Configure Environment Variables](#️-configure-environment-variables)
    - [Start the Containers](#-start-the-containers)
- [Configuration](#️-configuration)
    - [Environment Variables](#-environment-variables)
    - [Docker Compose Files](#-docker-compose-files)
    - [Container Structure](#-container-structure)
- [Usage](#-usage)
    - [Common Commands](#️-common-commands)
    - [Accessing the Application](#-accessing-the-application)
    - [Working with the Buildbox](#-working-with-the-buildbox)
    - [PHP Container Access](#-php-container-access)
    - [Database Management](#️-database-management)
- [Development](#-development)
    - [Adding Custom Modules](#-adding-custom-modules)
    - [Third-Party Module Integration](#-third-party-module-integration)
    - [Development Workflow](#-development-workflow)
- [Troubleshooting](#-troubleshooting)
    - [Docker Permissions](#-docker-permissions)
    - [Local Docker Registry](#-local-docker-registry)
    - [Common Issues](#-common-issues)
- [Security Considerations](#️-security-considerations)
- [Performance Optimization](#-performance-optimization)

## 🏠 Self-host Quickstart

For a stable webtrees installation, pull the pre-built image. No build step needed.

```shell
# 1. Grab the repo (the compose files reference local nginx configs)
git clone https://github.com/magicsunday/webtrees-docker.git
cd webtrees-docker

# 2. Create your .env from the template and edit DB credentials + WEBTREES_VERSION
cp .env.dist .env
$EDITOR .env

# 3. Standalone (binds nginx on APP_PORT, default 80)
echo 'COMPOSE_FILE=compose.yaml:compose.publish.yaml' >> .env
docker compose pull && docker compose up -d

# 4. Open http://localhost:${APP_PORT:-80} and run the webtrees setup wizard
```

Behind Traefik instead of binding a host port:

```shell
echo 'COMPOSE_FILE=compose.yaml:compose.traefik.yaml' >> .env
echo 'DEV_DOMAIN=webtrees.example.com' >> .env
docker compose pull && docker compose up -d
```

**Upgrades:** bump `WEBTREES_VERSION` in `.env`, `docker compose pull`, then **wipe the app volume** (`docker compose down && docker volume rm webtrees_app`) so the entrypoint re-seeds. Webtrees data and modules in named volumes survive.

**Secrets:** any env var ending in `_FILE` is read from its referenced file (Docker Swarm / Kubernetes secret-mount pattern). Example: `MARIADB_PASSWORD_FILE=/run/secrets/db_password`.

## 🧪 Module Developer Quickstart

For working on webtrees modules with live source bind-mount, xdebug, and the buildbox:

```shell
# Clone the repository
git clone git@github.com:magicsunday/webtrees-docker.git
cd webtrees-docker

# Run the setup script (interactive — picks dev vs traefik vs external DB)
./scripts/setup.sh

# Start the containers
make up

# Access Webtrees at http://localhost:50010
```

The rest of this README focuses on the developer workflow. Self-hosters can stop after the Quickstart above.

## 🧰 Requirements

Before you begin, ensure you have the following software installed:

* Docker
* Docker Compose (v2 "docker compose" or v1 "docker-compose")
* Git
* Bash

Notes:
- The setup script now checks for required tools (Docker, Docker Compose, Git, Make, sed) and aborts with actionable messages if something is missing.
- Both Docker Compose v2 (plugin) and v1 (standalone) are supported.
- The script works on GNU/Linux and macOS (BSD sed is handled).

## 🧩 Installing Modules (self-host)

The pre-built image bundles webtrees-core only. Custom modules can be added in
two ways, depending on whether the host file system is your source of truth or
you prefer to drive everything from inside the container.

### Option A — Host-side bind-mount (recommended)

Add `compose.modules.yaml` to the `COMPOSE_FILE` chain so a host directory
maps into the container's `modules_v4/`:

```shell
# Append to .env
COMPOSE_FILE=compose.yaml:compose.publish.yaml:compose.modules.yaml

# Drop your unpacked module into ./modules/
mkdir -p modules
unzip ~/Downloads/webtrees-fan-chart.zip -d modules/

# Restart so PHP-FPM and nginx pick the bind-mount up
docker compose restart phpfpm nginx
```

Modules placed here **survive image upgrades** — a `WEBTREES_VERSION` bump
re-seeds the `app:` volume, but your `./modules` directory is left alone.

When the entrypoint seeds the volume for the first time *with the overlay
active*, webtrees' shipped `modules_v4/README.md` lands in `./modules/`
(owned by uid 82 — the container's `www-data`). That is expected; remove it
if it bothers you.

### Option B — Shell into the container

If you don't want a bind-mount, drop into the running PHP-FPM container
straight into the modules directory:

```shell
make modules-shell
# inside the container:
curl -L <download-url> -o module.zip
unzip module.zip && rm module.zip
exit
```

Modules installed this way live inside the `app:` named volume. They are
preserved across container restarts but **wiped on a `WEBTREES_VERSION`
upgrade** (the entrypoint refuses to overwrite a populated volume, so you
must wipe it manually to re-seed — modules included).

For unattended module installs use the companion project
[magicsunday/webtrees-module-updater](https://github.com/magicsunday/webtrees-module-updater)
instead.

## 🔄 Switching Between Dev and Production Mode

The two modes are selected by whether `compose.development.yaml` is part of
the `COMPOSE_FILE` chain in `.env`:

| Mode | Effect |
|---|---|
| **Production** | Image-only build, named `app:` volume seeded on first run from the bundled webtrees release. nginx published on `APP_PORT` (or behind Traefik). |
| **Dev** (overlay added) | Bind-mounted `./app`, buildbox container, xdebug, browserless. `WEBTREES_AUTO_SEED=false` so the host bind-mount is never overwritten. |

Toggle via make:

```shell
make enable-dev-mode    # add compose.development.yaml to COMPOSE_FILE
make up                 # restart with the new chain

make disable-dev-mode   # remove compose.development.yaml from COMPOSE_FILE
make up                 # back to production

make dev-mode-status    # ON / OFF
```

The toggle only edits the `COMPOSE_FILE` chain in `.env`; everything else
(database credentials, host port, mail config, …) stays where it is.

## 🛠️ Setup and Installation

### 📥 Clone the Repository

```shell
git clone git@github.com:magicsunday/webtrees-docker.git
cd webtrees-docker
```

### ▶️ Run the Setup Script

The setup script will create the necessary configuration files:

```shell
./scripts/setup.sh
```

This script creates the `.env` file and prompts you for the required configuration variables.

### ⚙️ Configure Environment Variables

Edit the `.env` file to customize your installation. Important settings include:

- Database credentials
- PHP configuration
- Web server settings
- Application paths

### 🐳 Start the Containers

Launch the Docker containers:

```shell
make up
```

## ⚙️ Configuration

### 🔧 Environment Variables

The `.env` file contains all configurable options for the project. Key settings include:

- `MYSQL_ROOT_PASSWORD`: Root password for MariaDB
- `MYSQL_DATABASE`: Database name for Webtrees
- `MYSQL_USER`: Database user for Webtrees
- `MYSQL_PASSWORD`: Database password for Webtrees
- `PHP_MAX_EXECUTION_TIME`: Maximum execution time for PHP scripts
- `PHP_MEMORY_LIMIT`: Memory limit for PHP
- `ENFORCE_HTTPS`: Enable/disable HTTPS enforcement

### 🧩 Docker Compose Files

The project uses several Docker Compose files for different environments:

- `compose.yaml`: Base production configuration (db, phpfpm, nginx) — image only, no host port
- `compose.publish.yaml`: Publishes nginx on `APP_PORT` (use when running standalone, without Traefik)
- `compose.modules.yaml`: Bind-mounts `./modules` into the container's `modules_v4/` for host-side module installs
- `compose.pma.yaml`: phpMyAdmin for database management
- `compose.development.yaml`: Development overlay (buildbox, local volume bind-mounts, browserless)
- `compose.external.yaml`: External database and media configuration
- `compose.traefik.yaml`: Configuration for use with Traefik reverse proxy

### 🧱 Container Structure

The application consists of several containers:

1. **db**: MariaDB database (with health check)
2. **phpfpm**: PHP-FPM service with all required extensions (with health check)
3. **nginx**: Nginx web server (with health check)
4. **pma**: phpMyAdmin for database management (development only, via `compose.pma.yaml`)

## 📖 Usage

### ⌨️ Common Commands

- `make up`: Start all containers
- `make down`: Stop and remove all containers
- `make status`: Show the status of running containers
- `make logs`: Show container logs
- `make build`: Build/update Docker images
- `make apply-config`: Apply configuration changes
- `make bash`: Open a bash shell in the buildbox as the configured user
- `make bash-root`: Open a bash shell in the buildbox as root

### 🌐 Accessing the Application

After running `scripts/setup.sh` in development mode, the application is
accessible at:

- Webtrees: http://localhost:50010
- phpMyAdmin: http://localhost:50011

Standalone production stacks default to port 80 (set by `compose.publish.yaml`).
Set `APP_PORT` and `PMA_PORT` in `.env` to change the host ports. The nginx
port is only published when `compose.publish.yaml` is part of the
`COMPOSE_FILE` chain.

### 👩‍💻 Working with the Buildbox

The buildbox provides a development environment with all necessary tools:

```shell
make bash
```

### 🐘 PHP Container Access

To access the PHP container directly:

```shell
docker compose exec phpfpm bash
```

### 🗄️ Database Management

The project includes phpMyAdmin for database management. You can also access the database directly:

```shell
docker compose exec db mysql -u root -p
```

## 👩‍💻 Development

### 📦 Adding Custom Modules

To add custom modules, modify the `composer.json` in the "app" directory:

```json
{
    "name": "magicsunday/webtrees-base",
    "description": "Webtrees base installation",
    "license": "MIT",
    "authors": [
        {
            "name": "Rico Sonntag",
            "email": "mail@ricosonntag.de",
            "role": "Developer",
            "homepage": "https://www.ricosonntag.de/"
        }
    ],
    "config": {
        "preferred-install": {
            "*": "dist",
            "magicsunday/*": "source"
        },
        "allow-plugins": {
            "magicsunday/webtrees-module-installer-plugin": true
        }
    },
    "repositories": {
        "magicsunday/webtrees-statistics": {
            "type": "github",
            "url": "https://github.com/magicsunday/webtrees-statistics.git"
        }
    },
    "require": {
        "fisharebest/webtrees": "~2.2.0",
        "magicsunday/webtrees-module-base": "*",
        "magicsunday/webtrees-descendants-chart": "*",
        "magicsunday/webtrees-pedigree-chart": "*",
        "magicsunday/webtrees-fan-chart": "*"
    },
    "require-dev": {
        "magicsunday/webtrees-module-installer-plugin": "dev-WIP"
    },
    "minimum-stability": "dev",
    "prefer-stable": true
}
```

Then run `make composer-update` to install or update the packages.

### 🔌 Third-Party Module Integration

Third-party modules can be integrated using Composer. Add the module to the `require` section of your `composer.json` file and specify the repository if needed.

### 🔄 Development Workflow

1. Make changes to your code
2. Test changes in the development environment
3. If configuration changes are needed, update the `.env` file
4. Apply configuration changes with `make apply-config`
5. Restart the stack with `make up`

## 🔍 Troubleshooting

### 🔐 Docker Permissions

To run Docker as a non-root user, add your user to the "docker" group:

```shell
# Create the docker group if it doesn't exist
sudo groupadd docker

# Add your user to the docker group
sudo usermod -aG docker $USER

# Log out and log back in
# Verify that the group is set
groups
```

Please read the [Docker security documentation](https://docs.docker.com/engine/security/#docker-daemon-attack-surface) regarding possible security implications.

### 📦 Local Docker Registry

When using a local Docker Registry, you might encounter HTTPS-related errors. To allow HTTP access:

1. Modify `/etc/docker/daemon.json`:

```json
{
    "insecure-registries": [
        "http://your-registry-ip:5000"
    ]
}
```

2. Restart the Docker daemon:

```shell
sudo service docker restart
```

### ❗ Common Issues

- **Database connection errors**: Check your database credentials in the `.env` file
- **Permission issues**: Ensure proper file permissions in mounted volumes
- **Port conflicts**: Set `APP_PORT` and `PMA_PORT` in `.env` to remap the host ports when 50010/50011 (or 80, in standalone production) are already in use
- **GitHub API rate limit**: Composer uses the GitHub API to resolve packages from GitHub repositories. Without authentication, the limit is 60 requests per hour. If the [GitHub CLI](https://cli.github.com/) (`gh`) is installed and authenticated on the host, the token is picked up automatically. Otherwise, you can set `COMPOSER_AUTH` manually in your environment:
  ```shell
  export COMPOSER_AUTH='{"github-oauth":{"github.com":"YOUR_TOKEN"}}'
  ```

## 🚀 Production Deployment

For production, run the base `compose.yaml` plus either `compose.publish.yaml`
(standalone, binds `APP_PORT` on the host) or `compose.traefik.yaml`
(routes through Traefik, no host port). Do not combine the two.

Create `.env` first by copying `.env.dist` and filling in the database and
mail variables; `docker compose up` reads it automatically from the working
directory.

```shell
# Standalone, reachable on http://localhost:${APP_PORT:-80}
COMPOSE_FILE=compose.yaml:compose.publish.yaml docker compose up -d

# Behind Traefik (set DEV_DOMAIN to your hostname first)
COMPOSE_FILE=compose.yaml:compose.traefik.yaml docker compose up -d
```

### Production Checklist

- [ ] Set `ENVIRONMENT=production` in `.env`
- [ ] Set `ENFORCE_HTTPS=TRUE` in `.env`
- [ ] Use strong, unique passwords for `MARIADB_ROOT_PASSWORD` and `MARIADB_PASSWORD`
- [ ] Do **not** include `compose.pma.yaml` — phpMyAdmin should never be exposed in production
- [ ] Set up regular database backups (e.g. `docker compose exec db mariadb-dump ...`)
- [ ] Place behind a reverse proxy (Traefik, nginx) with TLS termination
- [ ] Monitor container health via `docker compose ps` or your orchestrator

### Database Backups

```shell
# Create a backup (uses MARIADB_ROOT_PASSWORD from .env)
source .env
docker compose exec db mariadb-dump -u root -p"${MARIADB_ROOT_PASSWORD}" webtrees > backup_$(date +%Y%m%d).sql

# Restore a backup
docker compose exec -T db mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" webtrees < backup.sql
```

## 🛡️ Security Considerations

- HTTPS enforcement can be enabled by setting `ENFORCE_HTTPS=TRUE` in the `.env` file
- Security headers are configured in `rootfs/etc/nginx/includes/security-headers.conf`
- Keep all containers updated with `make build` regularly
- Use strong passwords for database and admin accounts
- The `.env` file contains secrets and is created with restricted permissions (`chmod 600`)
- Never commit `.env` to version control
- phpMyAdmin (`compose.pma.yaml`) is for development only and should **never** be exposed publicly in production. For production database access, use SSH tunneling or a VPN instead
- xdebug is only installed in the development buildbox image, not in the production PHP-FPM image

## ⚡ Performance Optimization

- PHP opcache is enabled by default for better performance
- Adjust PHP settings in the `.env` file:
  - `PHP_MAX_EXECUTION_TIME`
  - `PHP_MAX_INPUT_VARS`
  - `PHP_MEMORY_LIMIT`
  - `PHP_POST_MAX_SIZE`
  - `PHP_UPLOAD_MAX_FILESIZE`
