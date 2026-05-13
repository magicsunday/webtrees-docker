# Env-var reference

Single-table inventory of every environment variable the stack reads.
Each row points at the canonical consumer (compose, entrypoint, installer
template, or one of the bundled scripts) and notes whether the name
overlaps with naming conventions other webtrees Docker stacks use.

The full hand-roll docblocks live in [`.env.dist`](../.env.dist); this
file is the at-a-glance map, not the source of truth.

**Scope.** Variables the official `php:*-fpm-alpine` and `nginx:*-alpine`
base images inject (`PHP_INI_DIR`, `NGINX_VERSION`, etc.) are not in
this table — they are upstream-image plumbing, not knobs this repo
asks operators to set. The entrypoint reads `PHP_INI_DIR` to locate
the bundled ini fragment but doesn't expect operators to override it.

CI-only provenance build args (`BUILD_DATE`, `VCS_REF` — injected by
`compose.development.yaml`'s build block and the GitHub Actions
workflow into the Dockerfile's OCI labels) are also out of scope for
the same reason.

## Runtime variables (compose-substituted or entrypoint-consumed)

| Variable | Default / fallback | Consumer | Purpose |
|---|---|---|---|
| `WEBTREES_VERSION` | image build-arg, no runtime fallback | `compose.yaml`, `Dockerfile`, `rootfs/docker-entrypoint.sh` | Pins the webtrees release the image bundles; the entrypoint also reads it for the AUTO_SEED state machine. |
| `PHP_VERSION` | image build-arg, no runtime fallback | `compose.yaml`, `Dockerfile` | Selects the `php:X.Y-fpm-alpine` base image. |
| `WEBTREES_NGINX_VERSION` | image build-arg, no runtime fallback | `compose.yaml`, `Dockerfile` | Selects the prebuilt nginx image tag (`<base>-r<config-revision>`). |
| `DOCKER_SERVER` | `ghcr.io/magicsunday` | `compose.yaml`, `compose.development.yaml`, `Dockerfile` | Registry namespace for all `${DOCKER_SERVER}/webtrees/...` image pulls. |
| `ENVIRONMENT` | entrypoint defaults to `production` if unset | `compose.yaml`, `rootfs/docker-entrypoint.sh` | Selects the PHP ini bundle (`development` / `production`). |
| `ENFORCE_HTTPS` | entrypoint defaults to disabled if unset | `compose.yaml`, `rootfs/docker-entrypoint.sh`, `rootfs/etc/nginx/...` | Case-insensitive `TRUE` enables the nginx HTTP→HTTPS redirect. |
| `APP_PORT` | compose default `80` (in `compose.publish.yaml`) | `compose.publish.yaml` | Host port nginx binds when the publish overlay is active. |
| `PMA_PORT` | compose default `50011` (in `compose.development.yaml`) | `compose.development.yaml` | Host port the phpMyAdmin overlay binds (dev-mode only). `compose.pma.yaml` only sets an in-container `PMA_PORT` for phpMyAdmin to use as the DB port; that's a different knob. |
| `MARIADB_HOST` | compose substitution defaults to `db` (the bundled service) | `compose.yaml`, `compose.external.yaml`, `compose.pma.yaml`, `rootfs/docker-entrypoint.sh` | DB hostname; also overloaded as the external Docker network name when `compose.external.yaml` is in the chain. |
| `MARIADB_PORT` | compose default `3306` | `compose.yaml`, `compose.pma.yaml`, `rootfs/docker-entrypoint.sh` | DB port. |
| `MARIADB_DATABASE` | `webtrees` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | DB name. |
| `MARIADB_USER` | `webtrees` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | App DB user. |
| `MARIADB_PASSWORD` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` | App DB password. Plaintext source; combine with `MARIADB_PASSWORD_FILE` for file-backed secrets. |
| `MARIADB_PASSWORD_FILE` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` (`*_FILE` expansion) | Docker-secrets-style path to a file whose content becomes `MARIADB_PASSWORD`. |
| `MARIADB_ROOT_PASSWORD` | none | `compose.yaml` | Root password for the bundled MariaDB container; required for the `db` service to start. |
| `MAIL_SMTP` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` | SMTP server (`host:port`). Currently no-op — `setup_mail` is disabled, tracked in #67. |
| `MAIL_DOMAIN` | `.env.dist` ships `example.org` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | "From" domain for outbound mail. No-op today: the entrypoint's `setup_mail` step is disabled, tracked in #67. When re-enabled, an unset value causes ssmtp to omit the `rewriteDomain` line entirely. |
| `MAIL_HOST` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` | Hostname identifier for outbound mail. See #67. |
| `PHP_MAX_EXECUTION_TIME` | entrypoint default `30` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | PHP ini setting. |
| `PHP_MEMORY_LIMIT` | entrypoint default `128M` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | PHP ini setting. The wizard ships `256M`. |
| `PHP_MAX_INPUT_VARS` | entrypoint default `1000` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | PHP ini setting. |
| `PHP_UPLOAD_MAX_FILESIZE` | bundled php.ini value | `compose.yaml`, `rootfs/docker-entrypoint.sh` | PHP ini setting. The wizard ships `128M`. |
| `PHP_POST_MAX_SIZE` | bundled php.ini value | `compose.yaml`, `rootfs/docker-entrypoint.sh` | PHP ini setting. The wizard ships `128M`. |
| `UPLOAD_LIMIT` | `.env.dist` ships `32M`; phpMyAdmin's own default applies when unset | `compose.pma.yaml` | phpMyAdmin's max SQL-file upload size. |
| `WEBTREES_TABLE_PREFIX` | entrypoint default `wt_` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | DB table prefix. Translates to webtrees' `tblpfx` config-ini key (different spelling, identical meaning). |
| `WEBTREES_REWRITE_URLS` | `.env.dist` ships `0` | `scripts/configuration` (dev install path) | URL-rewrite toggle. The dev install writes it into `config.ini.php`'s `rewrite_urls=`; the production installer wiring is tracked in #39. |
| `WEBTREES_AUTO_SEED` | `compose.yaml` sets `true`; `compose.development.yaml` overrides to `false` | `rootfs/docker-entrypoint.sh` | Triggers the first-run seed of `/var/www/html` from the bundled webtrees-dist. The wizard pins the value via the chosen compose chain. |
| `WT_ADMIN_USER` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` | Headless admin bootstrap: username. Consumed only by this stack's `setup_admin_user` entrypoint step, which feeds the value to webtrees' upstream `php index.php user --create` CLI. |
| `WT_ADMIN_PASSWORD` | none — prefer `WT_ADMIN_PASSWORD_FILE` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | Headless admin bootstrap: password (same lineage as `WT_ADMIN_USER`). |
| `WT_ADMIN_PASSWORD_FILE` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` (`*_FILE` expansion) | Docker-secrets-style path to a file whose content becomes `WT_ADMIN_PASSWORD`. |
| `WT_ADMIN_EMAIL` | `admin@example.org` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | Headless admin bootstrap: email. |
| `WT_ADMIN_REAL_NAME` | derived from `WT_ADMIN_USER` | `compose.yaml`, `rootfs/docker-entrypoint.sh` | Headless admin bootstrap: display name. |
| `COMPOSE_FILE` | none | Docker Compose itself (chain selection) | The dev-mode wizard writes the desired overlay chain. The production wizard renders a single self-contained `compose.yaml` and leaves this empty. Same semantic as Compose's own variable. |
| `COMPOSE_PROJECT_NAME` | `webtrees` | Docker Compose itself; interpolated into `compose.traefik.yaml`, `Make/application.mk`, `Make/docker.mk`, plus the `install` / `upgrade` / `switch` launchers | Project name for container/volume naming. Same semantic as Compose's own variable. |

## Dev-only or buildbox-scope

| Variable | Default / fallback | Consumer | Purpose |
|---|---|---|---|
| `APP_DIR` | `./app` | buildbox-side scripts only (`scripts/*.sh`, `rootfs/opt/user-entrypoint.sh`) | Local checkout path the buildbox container mounts. Not consumed by the production stack. |
| `MEDIA_DIR` | `./persistent/media` | `compose.development.yaml`, `compose.external.yaml` | Host path for the media bind-mount. Wizard-rendered standalone production stacks use a named Docker volume instead. |
| `NGINX_CONFIG_REVISION` | `1` | `compose.development.yaml` build-arg | Bumped when nginx config under `rootfs/etc/nginx/` changes; production runtime pulls the prebuilt image and ignores this. |
| `DEV_DOMAIN` | none | `compose.traefik.yaml`, `scripts/configuration`, `switch` (launcher), `Make/application.mk` (display), `Make/docker.mk` (PROJECT_URL substitution) | Reverse-proxy hostname (Traefik) AND the dev-install's `base_url`. Name is historical — see "Naming notes" below. |
| `LOCAL_USER_ID` | none | `compose.yaml`, `rootfs/docker-entrypoint.sh` (UID remap on bind-mounts), `rootfs/opt/user-entrypoint.sh` (buildbox user creation), buildbox scripts | Operator UID. Remap fires whenever this is set; wizard-rendered production stacks typically leave it unset. |
| `LOCAL_USER_NAME` | none | `rootfs/opt/user-entrypoint.sh` (buildbox `useradd`), `Make/application.mk` (display) | Operator username. Buildbox-only. |
| `LOCAL_GROUP_ID` | `82` | `compose.yaml`, `rootfs/docker-entrypoint.sh`, `rootfs/opt/user-entrypoint.sh`, buildbox scripts | Operator GID, paired with `LOCAL_USER_ID`. |
| `LOCAL_GROUP_NAME` | `www-data` | `rootfs/opt/user-entrypoint.sh` (buildbox `groupadd`), `scripts/update-languages.sh` (setfacl), `Make/application.mk` (display) | Operator group name. Buildbox-only. |
| `USE_EXISTING_DB` | unset → scripts treat as `1` | `scripts/install-application.sh` | Dev-mode toggle: assume an already-initialised DB, write `config.ini.php` from `.env`. |
| `WORK_DIR` | `$PWD` host-side | `compose.development.yaml`, `installer/webtrees_installer/*`, `install` launcher, `.github/workflows/build.yml` | Host cwd used as the bind-mount source. |
| `BROWSER_PORT` | `3000` | `compose.development.yaml` | Host port the headless-Chrome CDP exposes for Playwright-from-host tests. |

## Naming notes

This section is the second half of [issue #36](https://github.com/magicsunday/webtrees-docker/issues/36) — for every name that overlaps with conventions other webtrees / general container stacks use, either confirm the semantics align or note the divergence so a migrating operator isn't caught by surprise.

* **`MARIADB_*` block** — aligned with the MariaDB official image's own envs (`MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DATABASE`, `MARIADB_ROOT_PASSWORD`). Webtrees itself reads DB settings from `config.ini.php` (`dbhost`, `dbuser`, `dbpass`, `dbname`); the entrypoint translates the `MARIADB_*` envs into those keys via `php index.php config-ini`. Operators migrating from stacks that talk to the MariaDB image directly keep their secret names.
* **`WT_ADMIN_*` block** — this stack's own spelling, not an upstream webtrees convention. The variables are consumed only by `setup_admin_user` in `rootfs/docker-entrypoint.sh`, which passes them to webtrees' `php index.php user --create` CLI. Operators migrating from stacks that talk to webtrees directly (via `config.ini.php` or the upstream HTTP setup wizard) won't have these names pre-existing.
* **`WEBTREES_TABLE_PREFIX`** — aligned with webtrees' `tblpfx` config-ini key (different spelling, identical meaning).
* **`ENFORCE_HTTPS`** — case-insensitive `TRUE` enables the nginx redirect, anything else disables. Compatible with the common pattern in nginx-fronted webtrees stacks.
* **`COMPOSE_FILE` / `COMPOSE_PROJECT_NAME`** — these ARE Docker Compose's own variables, used here for their stock semantics. No collision.
* **`PHP_*` block** — these end up in `php.ini` as the same-named directives. Aligned.
* **`LOCAL_USER_ID` / `LOCAL_GROUP_ID`** — *naming friction*. Many community-built container images use `PUID` / `PGID` for the host-UID-remap concept. This stack uses `LOCAL_USER_ID` / `LOCAL_GROUP_ID` instead; the semantics are the same (host UID/GID the in-container user gets remapped to) but the spelling differs. The toggle name is sticky now because it ships in every existing operator's `.env`; renaming requires a deprecation window across at least one minor release. Tracking: this remains the spelling; PUID/PGID will not be silently picked up.
* **`DEV_DOMAIN`** — *naming friction*. The historical name suggests "development", but the variable is also consumed by `compose.traefik.yaml` (the Traefik production overlay) as the public Host-header value. Renaming to a neutral `PUBLIC_DOMAIN` is the right move for a future major bump; the name is preserved here until the wizard's compatibility window allows the migration.
* **`MAIL_*` block** — names align with common SMTP-relay conventions (`MAIL_SMTP=host:port`, `MAIL_DOMAIN`, `MAIL_HOST`), but the `setup_mail` entrypoint step that writes them into `ssmtp.conf` is currently disabled. Tracked in [issue #67](https://github.com/magicsunday/webtrees-docker/issues/67).
* **`DOCKER_SERVER`** — unique to this repo's image-pull substitution; not a name another stack uses. No collision risk.

## Renaming policy

No renames are landing in this audit pass — every name above either matches the upstream convention it's meant to mirror (the MariaDB block, the `WT_*` CLI bridge) or is sticky enough across operators' existing `.env` files that breaking the name would cost more than the naming friction. The friction cases (`LOCAL_USER_ID`/`LOCAL_GROUP_ID` vs `PUID`/`PGID`, and `DEV_DOMAIN`) are documented here as known divergences; either gets a deprecation alias when the wizard adds a one-minor-release compatibility window.
