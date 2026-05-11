# Phase 1: Image-Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `webtrees-php-full` (Magic-Sunday-Edition), `webtrees-nginx` image tracks plus an Admin-Bootstrap-Hook in the PHP entrypoint, and wire all four image tracks into CI. After Phase 1, a user can pull the new images and bring up a Magic-Sunday-Edition stack via the existing repo `compose.yaml`. Wizard, demo-tree, and documentation come in Phases 2+3.

**Architecture:** Refactor `Dockerfile` to introduce a shared `php-base` stage, then add four new stages — `webtrees-build-full`, `php-build-full`, `nginx-build` — alongside the existing tracks. Move nginx configs from the repo bind-mounts into the new `webtrees-nginx` image so production stacks stop needing a `git clone`. Add an opt-in headless setup hook (`setup_webtrees_bootstrap`) to the PHP entrypoint that consumes `WT_ADMIN_*` env vars and skips the browser-side webtrees setup wizard. Extend `.github/workflows/build.yml` to build all four targets per `dev/versions.json` matrix entry, plus a smoke-test job that brings each one up via the repo's `compose.yaml`.

**Tech Stack:** Docker multi-stage builds, Alpine Linux, PHP-FPM, nginx, MariaDB, Composer (`composer:2`), Bash, GitHub Actions, `docker/build-push-action@v5`, `composer-patches`. Tests in Bash following the pattern of `tests/test-entrypoint.sh`.

---

## Discovery (no code change)

### Task 1: Validate the headless-setup path for Admin-Bootstrap

The spec writes Pfad A: write `config.ini.php` directly + call `webtrees-cli` for migrate + user-create. Two unknowns must be resolved before any entrypoint code is written:

1. Does a `migrate` command exist in the webtrees CLI?
2. If yes — does running it with a hand-crafted `config.ini.php` against an empty MariaDB instance produce a working schema and an admin-creatable system?

**Files:** none (research, with optional addendum to spec)

- [ ] **Step 1:** Bring up the current dev stack so a baseline webtrees install exists.

```bash
cd /volume2/docker/webtrees
make up
docker compose ps   # all healthy
```

- [ ] **Step 2:** Enumerate webtrees CLI commands.

```bash
docker compose exec phpfpm php /var/www/html/index.php list
```

Expected: prints a Symfony-Console command list. Look for `migrate`, `tree:create`, `tree:import`, `user:create` (or `tree --create`, etc. — naming varies between webtrees versions). Record exact command names + their `--help` output.

- [ ] **Step 3:** Snapshot the existing `config.ini.php` for reference.

```bash
docker compose exec phpfpm cat /var/www/html/data/config.ini.php
```

Save its content locally for use in Step 5.

- [ ] **Step 4:** Tear down + recreate stack with a fresh DB volume to simulate a first-boot environment.

```bash
docker compose down
docker volume rm webtrees_app webtrees_database webtrees_media 2>/dev/null || true
docker compose up -d db init
# wait for db healthy
docker compose ps
```

- [ ] **Step 5:** Bring phpfpm up *without* the webtrees seed running setup. Manually write `config.ini.php` using credentials from `.env`, then run the candidate `migrate` (or equivalent) command.

```bash
docker compose up -d phpfpm
# wait for phpfpm healthy
docker compose exec phpfpm sh -c 'cat > /var/www/html/data/config.ini.php <<EOF
dbtype="mysql"
dbhost="db"
dbname="webtrees"
dbuser="webtrees"
dbpass="webtrees"
tblpfx="wt_"
EOF
chown www-data:www-data /var/www/html/data/config.ini.php
chmod 600 /var/www/html/data/config.ini.php'

# Try whichever command the listing from Step 2 surfaced:
docker compose exec phpfpm su www-data -s /bin/sh -c \
  'php /var/www/html/index.php migrate'
```

Expected outcome A — command exists and runs: DB schema is now populated. Proceed to Step 6.

Expected outcome B — no `migrate` command: try `db:migrate`, `database:migrate`, or check `setup` command. If none works, hitting `http://localhost/` once with a `User-Agent` triggers webtrees' lazy migration in PHP code. Verify with `curl -s http://localhost:50010/ | head` — schema should populate.

- [ ] **Step 6:** Attempt admin creation against the populated DB.

```bash
docker compose exec phpfpm su www-data -s /bin/sh -c \
  'php /var/www/html/index.php user:create \
    --username "admin" --realname "Admin" \
    --email "admin@example.org" --password "test1234" --admin'
# or `user --create` depending on Step 2 findings
```

Expected: user is created without error. Verify login at `http://localhost:50010/login` with `admin` / `test1234`.

- [ ] **Step 7:** Record findings.

Append an addendum section to the spec at `docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md` under a new heading **"Discovery findings (2026-05-11)"** with:

- Exact webtrees CLI command names (`migrate` / `db:migrate` / triggers lazy migration via HTTP)
- The exact `user --create` / `user:create` command signature
- Any unexpected behavior (e.g., webtrees rejects manual `config.ini.php`; needs additional bootstrap step)
- The Bootstrap-Hook code path Task 9 will follow

- [ ] **Step 8:** Tear down test stack, restore working state.

```bash
docker compose down
docker volume rm webtrees_app webtrees_database webtrees_media 2>/dev/null || true
make up
```

No commit — this task is research, the spec addendum is committed manually by the user.

---

## Dockerfile-Refactor

### Task 2: Extract `php-base` stage

Pull the PHP runtime + extensions + entrypoint copies out of `php-build` into a new `php-base` stage that both `php-build` and the upcoming `php-build-full` can derive from. Without this refactor, `php-build-full` would either duplicate ~30 lines of extension installs or stack a second `/opt/webtrees-dist` on top of `php-build`'s layer (bloat).

**Files:**
- Modify: `Dockerfile:83–152` (existing `php-build` stage split into `php-base` + minimal `php-build`)

- [ ] **Step 1:** Open `Dockerfile`. Replace the section starting at line 83 (`#######` / `# PHP #` / `#######`) up to the `ENTRYPOINT`/`CMD` block at line 152 with the following two-stage layout. Preserve the `ARG` re-declarations and `LABEL` block unchanged from the original.

```dockerfile
###############
# PHP RUNTIME #
###############
# Shared base: PHP-FPM, extensions, entrypoint. Both production tracks
# (php-build core, php-build-full Magic-Sunday-Edition) derive from this
# stage so the PHP runtime is built once.
FROM php:${PHP_VERSION}-fpm-alpine AS php-base

ARG PHP_VERSION=8.3

# docker-entrypoint.sh dependencies
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    tzdata

# Add PHP extension installer
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

# Install required PHP extensions
# pdo_sqlite is included even though the default compose uses MariaDB — keeps
# the SQLite variant from Cluster B as an env-var-only switch later.
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
        apcu \
        exif \
        gd \
        imagick \
        intl \
        opcache \
        pdo_mysql \
        pdo_sqlite \
        zip

# Copy our custom configuration files
COPY rootfs/usr/local/etc/php/conf.d/*.ini $PHP_INI_DIR/conf.d/

# Entrypoint
COPY rootfs/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["php-fpm"]


#######################
# WEBTREES CORE IMAGE #
#######################
FROM php-base AS php-build

# Re-declare ARGs (out of scope across FROM boundaries)
ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG WEBTREES_VERSION=2.2.6

LABEL org.opencontainers.image.title="Webtrees PHP-FPM" \
      org.opencontainers.image.description="PHP-FPM runtime with bundled webtrees ${WEBTREES_VERSION}." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WEBTREES_VERSION}-php${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="php:${PHP_VERSION}-fpm-alpine" \
      org.opencontainers.image.ref.name="webtrees/php:${PHP_VERSION}" \
      net.webtrees.upgrade-locked="true"

# Bundle the composer-installed webtrees for first-run initialisation.
COPY --from=webtrees-build /opt/webtrees-dist /opt/webtrees-dist
```

- [ ] **Step 2:** Build the unchanged target to verify identical behavior.

```bash
docker build --target php-build \
    --build-arg PHP_VERSION=8.3 \
    --build-arg WEBTREES_VERSION=2.2.6 \
    -t webtrees-php-test:phase1-task2 .
```

Expected: build succeeds. Note the image size — should be roughly the same as before (within ~5 MB due to the new `pdo_sqlite` extension).

- [ ] **Step 3:** Run a quick functional smoke check.

```bash
# Verify entrypoint still loads and PHP-FPM starts under it
docker run --rm -d --name wt-task2-smoke \
    -e WEBTREES_AUTO_SEED=false \
    -e ENVIRONMENT=production \
    webtrees-php-test:phase1-task2

sleep 3
docker logs wt-task2-smoke | tail -20
docker exec wt-task2-smoke pgrep -f php-fpm
docker stop wt-task2-smoke
```

Expected: logs show entrypoint banner + `Setting up PHP configuration`; `pgrep` returns a PID.

- [ ] **Step 4:** Run the existing entrypoint tests.

```bash
TEST_IMAGE=webtrees-php-test:phase1-task2 ./tests/test-entrypoint.sh
```

Expected: all tests pass. If any fails, the refactor changed observable behavior — fix before committing.

- [ ] **Step 5:** Tell the user the task is ready for them to commit.

```
Task 2 ready to commit:
  git add Dockerfile
  git commit -m "Extract php-base stage from php-build"
```

(Do not run `git commit` yourself — repo standing order says no commits in this root.)

---

### Task 3: Rename `setup/composer.json` → `setup/composer-core.json`

Make room for the Magic-Sunday-Edition manifest by giving the core manifest a name that explicitly identifies it as the "core" variant.

**Files:**
- Rename: `setup/composer.json` → `setup/composer-core.json`
- Modify: `Dockerfile:22` (COPY path)
- Modify: `scripts/install-application.sh:28` (cp path)
- Modify: `Dockerfile:4` (comment referencing the path)
- Modify: `Dockerfile:28` (comment referencing the path)

- [ ] **Step 1:** Rename the file.

```bash
git mv setup/composer.json setup/composer-core.json
```

- [ ] **Step 2:** Update `Dockerfile:22`.

```dockerfile
COPY setup/composer-core.json /build/composer.json
```

- [ ] **Step 3:** Update `Dockerfile:4` (comment).

```dockerfile
# Throwaway stage that composer-installs webtrees from setup/composer-core.json,
```

- [ ] **Step 4:** Update `Dockerfile:28` (comment).

```dockerfile
 # setup/composer-core.json carries a "~2.2.0" range for the dev bootstrap; the
```

- [ ] **Step 5:** Update `scripts/install-application.sh:28`.

```bash
    cp -r "${APP_DIR}"/../setup/composer-core.json "${APP_DIR}/composer.json"
```

Note: the destination filename stays `composer.json` (webtrees expects that name in the app directory) — only the source file is renamed.

- [ ] **Step 6:** Verify no other references.

```bash
grep -rn "setup/composer\.json" \
    --include="*.sh" --include="*.mk" --include="Makefile" \
    --include="*.yml" --include="*.yaml" --include="Dockerfile*" \
    | grep -v "^app/\|^docs/\|^persistent/\|^\.idea/"
```

Expected: no results.

- [ ] **Step 7:** Build to verify the core image still works.

```bash
docker build --target php-build \
    --build-arg WEBTREES_VERSION=2.2.6 \
    -t webtrees-php-test:phase1-task3 .
```

Expected: build succeeds, image size unchanged from Task 2.

- [ ] **Step 8:** Verify dev install path still works.

```bash
make down
rm -rf app/composer.json app/composer.lock app/vendor   # only if you have a clean slate to test
make install   # invokes scripts/install-application.sh
ls -la app/composer.json   # should exist, content from composer-core.json
```

Expected: `app/composer.json` is created.

- [ ] **Step 9:** Ready to commit.

```
Task 3 ready to commit:
  git add setup/composer-core.json Dockerfile scripts/install-application.sh
  # Note: git tracks the rename automatically via git mv
  git commit -m "Rename setup/composer.json to setup/composer-core.json"
```

---

### Task 4: Create `setup/composer-full.json` for Magic-Sunday-Edition

The Full edition pre-bakes the four Magic-Sunday chart modules. `allow-plugins` stays restrictive (only `cweagans/composer-patches` is whitelisted), so even if a module's transitive deps drag in `magicsunday/webtrees-module-installer-plugin`, composer will not execute it — the modules land in `vendor/magicsunday/...` and are loaded via the existing `VendorModuleService` patch.

**Files:**
- Create: `setup/composer-full.json`

- [ ] **Step 1:** Write the file. Content based on `setup/composer-core.json` plus the Magic-Sunday `require` block.

```json
{
    "name": "magicsunday/webtrees-base-full",
    "description": "Docker-based deployment with bundled Magic-Sunday charts.",
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
            "*": "dist"
        },
        "allow-plugins": {
            "cweagans/composer-patches": true
        },
        "sort-packages": true
    },
    "require": {
        "fisharebest/webtrees": "~2.2.0",
        "cweagans/composer-patches": "^1.7",
        "magicsunday/webtrees-fan-chart": "*",
        "magicsunday/webtrees-pedigree-chart": "*",
        "magicsunday/webtrees-descendants-chart": "*",
        "magicsunday/webtrees-statistics": "*"
    },
    "extra": {
        "patches": {
            "fisharebest/webtrees": {
                "Disable the in-app upgrade prompt (bundled image is immutable)": "patches/disable-upgrade-prompt.patch",
                "Add VendorModuleService for composer-installed modules": "patches/add-vendor-module-service.patch"
            }
        }
    }
}
```

- [ ] **Step 2:** Validate JSON syntax.

```bash
docker run --rm -v "$PWD/setup:/s" alpine:3.20 sh -c \
    'apk add --no-cache jq >/dev/null && jq . /s/composer-full.json >/dev/null'
```

Expected: no output, exit code 0.

- [ ] **Step 3:** Verify in a one-shot composer run that the dependency graph resolves and that no plugin from the module-installer-plugin family gets activated.

```bash
docker run --rm -v "$PWD/setup:/build" \
    -e COMPOSER_HOME=/tmp/composer \
    -w /build composer:2 \
    composer install \
        --dry-run \
        --no-dev \
        --no-scripts \
        --no-progress \
        --no-interaction \
        --prefer-dist \
        --ignore-platform-req=ext-gd \
        --ignore-platform-req=ext-intl \
        --ignore-platform-req=ext-exif \
        --ignore-platform-req=ext-imagick \
        --ignore-platform-req=ext-zip \
        --working-dir=/build 2>&1 | grep -iE 'magicsunday|plugin|warn' | head -30
```

Expected: list shows `magicsunday/webtrees-fan-chart`, `pedigree-chart`, `descendants-chart`, `statistics` being resolved. No `webtrees-module-installer-plugin` is *activated* (line about "not allowed plugin" is OK; line about "plugin executed" is NOT OK).

If the plugin tries to run despite `allow-plugins` restriction, add `"replace": { "magicsunday/webtrees-module-installer-plugin": "*" }` to the manifest and re-test.

- [ ] **Step 4:** Ready to commit.

```
Task 4 ready to commit:
  git add setup/composer-full.json
  git commit -m "Add composer manifest for Magic-Sunday-Edition"
```

---

### Task 5: Add `webtrees-build-full` Dockerfile stage

This stage mirrors `webtrees-build` but consumes `setup/composer-full.json` instead. Layout-promotion (move `vendor/` + `public/` + `data/` into `/opt/webtrees-dist/html/`) is identical to the core stage.

**Files:**
- Modify: `Dockerfile` (insert new stage after `webtrees-build`, before `php-base`)

- [ ] **Step 1:** Add the new stage immediately after the existing `webtrees-build` stage. Find the line `#######` at line 83 (start of the PHP section) — the new stage goes before it.

```dockerfile
##########################
# WEBTREES BUILD (FULL)  #
##########################
# Magic-Sunday-Edition: webtrees core + fan/pedigree/descendants/statistics
# charts. Same install pipeline as webtrees-build, different composer manifest.
FROM composer:2 AS webtrees-build-full
ARG WEBTREES_VERSION=2.2.6

WORKDIR /build

COPY setup/composer-full.json /build/composer.json
COPY setup/patches /build/patches
COPY setup/public /build/public

RUN [ -n "${WEBTREES_VERSION}" ] || { echo "WEBTREES_VERSION cannot be empty" >&2; exit 1; } \
 && sed -i "s|\"fisharebest/webtrees\": \"[^\"]*\"|\"fisharebest/webtrees\": \"${WEBTREES_VERSION}\"|" composer.json \
 && composer install \
        --no-dev \
        --no-scripts \
        --no-progress \
        --no-interaction \
        --classmap-authoritative \
        --prefer-dist \
        --ignore-platform-req=ext-gd \
        --ignore-platform-req=ext-intl \
        --ignore-platform-req=ext-exif \
        --ignore-platform-req=ext-imagick \
        --ignore-platform-req=ext-zip \
 # Patch-applied guards (same sentinels as core)
 && grep -q "Upgrade-lock: bundled image is immutable" \
        vendor/fisharebest/webtrees/app/Services/UpgradeService.php \
 && test -f vendor/fisharebest/webtrees/app/Services/Composer/VendorModuleService.php \
 && grep -q 'merge($this->vendorModules())' \
        vendor/fisharebest/webtrees/app/Services/ModuleService.php \
 && ! find patches -mindepth 1 -type f ! -name '*.patch' | grep -q . \
 # Verify Magic-Sunday modules landed in vendor/ (not modules_v4/)
 && test -d vendor/magicsunday/webtrees-fan-chart \
 && test -d vendor/magicsunday/webtrees-pedigree-chart \
 && test -d vendor/magicsunday/webtrees-descendants-chart \
 && test -d vendor/magicsunday/webtrees-statistics \
 # Layout promotion (same as core)
 && mv vendor/fisharebest/webtrees/data data \
 && ln -s ../../../data vendor/fisharebest/webtrees/data \
 && mkdir -p /opt/webtrees-dist/html \
 && mv composer.json composer.lock vendor public data /opt/webtrees-dist/html/ \
 && rm -rf /build/patches \
 && test -f /opt/webtrees-dist/html/public/index.php \
 && test -d /opt/webtrees-dist/html/vendor/fisharebest/webtrees \
 && test -L /opt/webtrees-dist/html/vendor/fisharebest/webtrees/data
```

- [ ] **Step 2:** Build only the new stage.

```bash
docker build --target webtrees-build-full \
    --build-arg WEBTREES_VERSION=2.2.6 \
    -t webtrees-build-full:phase1-task5 .
```

Expected: build succeeds. Tag is used only locally for inspection.

- [ ] **Step 3:** Inspect the result.

```bash
docker run --rm webtrees-build-full:phase1-task5 \
    sh -c 'ls /opt/webtrees-dist/html/vendor/magicsunday/'
```

Expected output:

```
webtrees-descendants-chart
webtrees-fan-chart
webtrees-module-base
webtrees-pedigree-chart
webtrees-statistics
```

(`webtrees-module-base` comes in as transitive dependency.)

- [ ] **Step 4:** Verify no module-installer-plugin executed.

```bash
docker run --rm webtrees-build-full:phase1-task5 \
    sh -c 'ls /opt/webtrees-dist/html/vendor/fisharebest/webtrees/modules_v4/ 2>/dev/null | grep -i magicsunday || echo "OK: no magicsunday under modules_v4/"'
```

Expected: prints `OK: no magicsunday under modules_v4/`. If a magicsunday folder is listed, the plugin executed — go back to Task 4 Step 3 and add the `replace` clause.

- [ ] **Step 5:** Ready to commit.

```
Task 5 ready to commit:
  git add Dockerfile
  git commit -m "Add webtrees-build-full stage for Magic-Sunday-Edition"
```

---

### Task 6: Add `php-build-full` stage

Pairs `webtrees-build-full` with `php-base` to produce the final `webtrees-php-full` image.

**Files:**
- Modify: `Dockerfile` (insert new stage after `php-build`)

- [ ] **Step 1:** Add the new stage immediately after `php-build` (which ends at `COPY --from=webtrees-build /opt/webtrees-dist /opt/webtrees-dist` per the layout from Task 2).

```dockerfile
##############################
# WEBTREES FULL EDITION      #
##############################
FROM php-base AS php-build-full

ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG WEBTREES_VERSION=2.2.6

LABEL org.opencontainers.image.title="Webtrees PHP-FPM (Magic-Sunday-Edition)" \
      org.opencontainers.image.description="PHP-FPM runtime with bundled webtrees ${WEBTREES_VERSION} + Magic-Sunday charts (fan, pedigree, descendants, statistics)." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WEBTREES_VERSION}-php${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="php:${PHP_VERSION}-fpm-alpine" \
      org.opencontainers.image.ref.name="webtrees/php-full:${PHP_VERSION}" \
      net.webtrees.upgrade-locked="true" \
      net.webtrees.edition="full"

COPY --from=webtrees-build-full /opt/webtrees-dist /opt/webtrees-dist
```

- [ ] **Step 2:** Build the target.

```bash
docker build --target php-build-full \
    --build-arg PHP_VERSION=8.3 \
    --build-arg WEBTREES_VERSION=2.2.6 \
    -t webtrees-php-full-test:phase1-task6 .
```

Expected: build succeeds. Image is larger than core (~50–80 MB more for the four modules).

- [ ] **Step 3:** Verify edition label.

```bash
docker inspect webtrees-php-full-test:phase1-task6 \
    --format '{{ index .Config.Labels "net.webtrees.edition" }}'
```

Expected output: `full`

- [ ] **Step 4:** Smoke test — image starts, entrypoint runs.

```bash
docker run --rm -d --name wt-task6-smoke \
    -e WEBTREES_AUTO_SEED=false \
    -e ENVIRONMENT=production \
    webtrees-php-full-test:phase1-task6
sleep 3
docker logs wt-task6-smoke | tail -10
docker stop wt-task6-smoke
```

Expected: same banner as core. Webtrees core + Magic-Sunday modules sit at `/opt/webtrees-dist/html/`; they are only seeded into `/var/www/html/` when `WEBTREES_AUTO_SEED=true`.

- [ ] **Step 5:** Ready to commit.

```
Task 6 ready to commit:
  git add Dockerfile
  git commit -m "Add php-build-full stage for Magic-Sunday-Edition image"
```

---

### Task 7: Add `nginx-build` stage and override-hook directive

Move nginx configs from repo bind-mounts into an image, plus add an empty `/etc/nginx/conf.d/custom/` directory that users can override-mount into.

**Files:**
- Modify: `Dockerfile` (add new stage at the end, after `build-box`)
- Modify: `rootfs/etc/nginx/conf.d/default.conf:65` (insert include directive)

- [ ] **Step 1:** Update `rootfs/etc/nginx/conf.d/default.conf`. Find the line `include includes/php-proxy.conf;` (line 65 in the current file) and add a new include directly above it.

Replace:

```nginx
    include includes/php-proxy.conf;
}
```

with:

```nginx
    include includes/php-proxy.conf;

    # User-supplied snippets — leave the directory empty by default; users
    # bind-mount their own .conf files in via compose.override.yaml.
    include /etc/nginx/conf.d/custom/*.conf;
}
```

The `include` with glob pattern is no-op when the directory is empty.

- [ ] **Step 2:** Append the new `nginx-build` stage to `Dockerfile`. Add it after the existing `build-box` stage (the last stage in the file).

```dockerfile
##################
# NGINX          #
##################
# Pre-baked nginx with webtrees configs and an empty /etc/nginx/conf.d/custom/
# directory that users override-mount for their own snippets.
FROM nginx:1.28-alpine AS nginx-build

ARG NGINX_CONFIG_REVISION=1
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="Webtrees nginx" \
      org.opencontainers.image.description="nginx with webtrees configs and override-hook." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="1.28-r${NGINX_CONFIG_REVISION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="nginx:1.28-alpine" \
      org.opencontainers.image.ref.name="webtrees/nginx:1.28-r${NGINX_CONFIG_REVISION}"

# Baked configs: conf.d, includes, templates.
COPY rootfs/etc/nginx/conf.d /etc/nginx/conf.d
COPY rootfs/etc/nginx/includes /etc/nginx/includes
COPY rootfs/etc/nginx/templates /etc/nginx/templates

# Empty override directory — users mount their own snippets in.
RUN mkdir -p /etc/nginx/conf.d/custom

# Validate config at build time so we fail fast on syntax errors.
RUN nginx -t -c /etc/nginx/nginx.conf 2>&1 | tee /tmp/nginx-t.log \
 && grep -q "syntax is ok" /tmp/nginx-t.log \
 && grep -q "test is successful" /tmp/nginx-t.log
```

- [ ] **Step 3:** Build the target.

```bash
docker build --target nginx-build \
    --build-arg NGINX_CONFIG_REVISION=1 \
    -t webtrees-nginx-test:phase1-task7 .
```

Expected: build succeeds. The `nginx -t` step at build time confirms the config parses cleanly.

- [ ] **Step 4:** Inspect.

```bash
docker run --rm webtrees-nginx-test:phase1-task7 \
    ls -la /etc/nginx/conf.d/
```

Expected output includes `default.conf` and a `custom` directory.

```bash
docker run --rm webtrees-nginx-test:phase1-task7 \
    grep "conf.d/custom" /etc/nginx/conf.d/default.conf
```

Expected: prints the `include /etc/nginx/conf.d/custom/*.conf;` line.

- [ ] **Step 5:** Smoke test — nginx serves a 404 (no upstream).

```bash
docker run --rm -d --name wt-task7-nginx -p 18080:80 webtrees-nginx-test:phase1-task7
sleep 2
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:18080/
docker stop wt-task7-nginx
```

Expected output: `502` (no php-fpm upstream) or `404`. Anything ≥500/<600 confirms nginx itself is up. A `000` or connection refused means the container failed to start.

- [ ] **Step 6:** Ready to commit.

```
Task 7 ready to commit:
  git add Dockerfile rootfs/etc/nginx/conf.d/default.conf
  git commit -m "Add webtrees-nginx image with override-hook directory"
```

---

## Compose-Anpassungen

### Task 8: Switch base `compose.yaml` to the new `webtrees-nginx` image

Make the repo's `compose.yaml` reference the new pre-baked nginx image instead of bind-mounting configs from `./rootfs/`. The Dev overlay still bind-mounts configs so contributors can edit live.

**Files:**
- Modify: `compose.yaml` (nginx service)
- Modify: `compose.development.yaml` (add nginx build context + restore bind-mounts as writable)
- Modify: `.env.dist` (add `WEBTREES_NGINX_VERSION`)

- [ ] **Step 1:** Update `compose.yaml` nginx service. Find the section starting at line 96 (`# Nginx web server`) and replace through line 126 with:

```yaml
    nginx:
        depends_on:
            phpfpm:
                condition: service_healthy
        image: ${DOCKER_SERVER}/webtrees/nginx:${WEBTREES_NGINX_VERSION}
        environment:
            - ENFORCE_HTTPS
        healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost/ -o /dev/null || exit 1"]
            interval: 10s
            timeout: 5s
            retries: 3
            start_period: 5s
        restart: unless-stopped
        volumes:
            - app:/var/www/html:ro
            - media:/var/www/html/data/media:ro
            - /etc/timezone:/etc/timezone:ro
            - /etc/localtime:/etc/localtime:ro
        networks:
            - default
```

- [ ] **Step 2:** Update `compose.development.yaml` to add a build context for nginx and restore the bind-mounts (writable, so devs can edit live).

Find the `phpfpm:` service block (around line 90) and add the following block after it (before the `# Nginx host-port publishing...` comment):

```yaml
    # In dev mode, build webtrees-nginx locally + bind-mount configs writable
    # so changes apply via `nginx -s reload` without an image rebuild.
    nginx:
        build:
            context: .
            dockerfile: ./Dockerfile
            target: nginx-build
            args:
                - NGINX_CONFIG_REVISION
                - VCS_REF
                - BUILD_DATE
        volumes:
            - ./rootfs/etc/nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf
            - ./rootfs/etc/nginx/includes:/etc/nginx/includes
            - ./rootfs/etc/nginx/templates:/etc/nginx/templates
```

- [ ] **Step 3:** Update `.env.dist`. Find the `# Docker Server` section (around line 146) and add a new variable block above it:

```bash
##################
# Image versions #
##################

# nginx image revision (eigener Tag-Track, entkoppelt von webtrees-/PHP-Versionen).
# Schema: <nginx-base>-r<config-revision>, z. B. 1.28-r1.
# Bei Konfig-Änderungen unter rootfs/etc/nginx/ wird die r-Nummer inkrementiert.
WEBTREES_NGINX_VERSION=1.28-r1

NGINX_CONFIG_REVISION=1
```

- [ ] **Step 4:** Also update your local `.env` to mirror the new variable.

```bash
grep -q '^WEBTREES_NGINX_VERSION=' .env || echo 'WEBTREES_NGINX_VERSION=1.28-r1' >> .env
grep -q '^NGINX_CONFIG_REVISION=' .env || echo 'NGINX_CONFIG_REVISION=1' >> .env
```

- [ ] **Step 5:** Rebuild dev stack to verify the bind-mount fallback works.

```bash
make down
make build
make up
docker compose ps
curl -sf http://localhost:50010/ -o /dev/null && echo "nginx OK"
```

Expected: stack comes up healthy, curl returns 200 (or a redirect — `-sf` follows it).

- [ ] **Step 6:** Verify the prod-style image build is referenced correctly (no bind-mounts) by manually disabling the dev overlay temporarily.

```bash
make disable-dev-mode  # legacy command, still works in Phase 1; will be removed in Phase 3
make build
make up
curl -sf http://localhost/ -o /dev/null && echo "nginx OK (prod-style)"
make enable-dev-mode
make up
```

Expected: in prod-style mode, nginx pulls/uses `webtrees-nginx:1.28-r1` and serves correctly without `./rootfs/` bind-mounts.

- [ ] **Step 7:** Ready to commit.

```
Task 8 ready to commit:
  git add compose.yaml compose.development.yaml .env.dist
  git commit -m "Switch base compose.yaml to webtrees-nginx image"
```

---

## Admin-Bootstrap-Hook

### Task 9: Add `setup_webtrees_bootstrap` to entrypoint

Opt-in via `WT_ADMIN_USER`. When set, writes `config.ini.php` if missing, triggers schema migration, creates the admin user, and writes a marker file. Idempotent via the marker. Implementation details depend on Task 1 findings — adjust command names if `migrate` is not the right verb.

**Files:**
- Modify: `rootfs/docker-entrypoint.sh` (add function + call from `main()`)

- [ ] **Step 1:** Open `rootfs/docker-entrypoint.sh`. After the `setup_webtrees_dist` function (ends around line 231 with `return 0; }`), add the new function.

```bash
# Headless bootstrap: when WT_ADMIN_USER is set, write a minimal config.ini.php,
# trigger webtrees' DB migration (via the CLI command discovered in Task 1),
# and create the admin user via the CLI. Idempotent via a marker file. Opt-in
# only — without WT_ADMIN_USER the function is a no-op and the browser-side
# setup wizard handles things as before.
#
# Requires the following env vars (consumed via _FILE indirection elsewhere):
#   WT_ADMIN_USER          username for the admin account
#   WT_ADMIN_EMAIL         email
#   WT_ADMIN_PASSWORD      password (typically expanded from WT_ADMIN_PASSWORD_FILE)
#   MARIADB_HOST, MARIADB_USER, MARIADB_PASSWORD, MARIADB_DATABASE
setup_webtrees_bootstrap() {
    if [[ -z "${WT_ADMIN_USER:-}" ]]; then
        return 0
    fi

    if [[ -z "${WT_ADMIN_PASSWORD:-}" ]]; then
        log_error "WT_ADMIN_USER set but WT_ADMIN_PASSWORD is empty (forgot WT_ADMIN_PASSWORD_FILE?)"
        return 1
    fi

    local marker="/var/www/.webtrees-bootstrapped"
    local config="/var/www/html/data/config.ini.php"

    if [[ -f "$marker" ]]; then
        return 0
    fi

    # Write minimal config.ini.php if not present (e.g., fresh seed).
    if [[ ! -f "$config" ]]; then
        log_success "Writing initial config.ini.php for headless bootstrap"
        cat > "$config" <<EOF
dbtype="mysql"
dbhost="${MARIADB_HOST:-db}"
dbname="${MARIADB_DATABASE:-webtrees}"
dbuser="${MARIADB_USER:-webtrees}"
dbpass="${MARIADB_PASSWORD}"
tblpfx="${WEBTREES_TABLE_PREFIX:-wt_}"
EOF
        chown www-data:www-data "$config"
        chmod 600 "$config"
    fi

    # Trigger DB schema migration. Exact command name comes from Task 1 discovery.
    # ── PLACEHOLDER ── replace `migrate` with the verb established in Task 1 ──
    log_success "Running webtrees DB migration"
    if ! su www-data -s /bin/sh -c \
        'php /var/www/html/index.php migrate' 2>&1; then
        log_error "Webtrees DB migration failed — marker not set, will retry on next start"
        return 1
    fi

    # Create admin user. ── PLACEHOLDER ── replace command syntax per Task 1 ──
    log_success "Creating admin user: ${WT_ADMIN_USER}"
    if ! su www-data -s /bin/sh -c "
        php /var/www/html/index.php user:create \
            --username '${WT_ADMIN_USER}' \
            --realname '${WT_ADMIN_USER}' \
            --email '${WT_ADMIN_EMAIL:-admin@example.org}' \
            --password '${WT_ADMIN_PASSWORD}' \
            --admin
    " 2>&1; then
        # Tolerate "user already exists" — set marker anyway, since the user
        # was likely created on a previous failed run.
        log_warn "user:create returned non-zero — admin may already exist, marking bootstrap done"
    fi

    if ! touch "$marker"; then
        log_error "Cannot create marker $marker — bootstrap will re-run on every start"
        return 1
    fi
    chown www-data:www-data "$marker" 2>/dev/null || true

    return 0
}
```

> ⚠ The two `── PLACEHOLDER ──` lines reference the exact CLI command names. If Task 1 found that webtrees uses different verbs (e.g., `db:migrate` instead of `migrate`, or `user --create` instead of `user:create`), update those lines before committing.

- [ ] **Step 2:** Wire the function into `main()`. Find the `setup_webtrees_dist` call (around line 413 in the existing file) and add the new call directly below it.

Replace:

```bash
    # Seed bundled webtrees into the app volume when configured to (production
    # mode, first run). Fail fast on copy errors so php-fpm does not start
    # against a broken tree.
    if ! setup_webtrees_dist; then
        log_error "Webtrees first-run initialisation failed — refusing to start"
        exit 1
    fi
```

with:

```bash
    # Seed bundled webtrees into the app volume when configured to (production
    # mode, first run). Fail fast on copy errors so php-fpm does not start
    # against a broken tree.
    if ! setup_webtrees_dist; then
        log_error "Webtrees first-run initialisation failed — refusing to start"
        exit 1
    fi

    # Opt-in headless bootstrap: writes config.ini.php + migrates DB + creates
    # admin user when WT_ADMIN_USER is set. No-op otherwise.
    if ! setup_webtrees_bootstrap; then
        log_error "Webtrees bootstrap failed — refusing to start"
        exit 1
    fi
```

- [ ] **Step 3:** Rebuild the php-base image with the new entrypoint.

```bash
docker build --target php-build \
    --build-arg WEBTREES_VERSION=2.2.6 \
    -t webtrees-php-test:phase1-task9 .
```

Expected: build succeeds.

- [ ] **Step 4:** Quick smoke check (the deep tests are in Task 10).

```bash
docker run --rm webtrees-php-test:phase1-task9 \
    bash -c 'grep -q "setup_webtrees_bootstrap" /docker-entrypoint.sh && echo "OK: function present"'
```

Expected: `OK: function present`.

- [ ] **Step 5:** Ready to commit.

```
Task 9 ready to commit:
  git add rootfs/docker-entrypoint.sh
  git commit -m "Add setup_webtrees_bootstrap entrypoint hook for opt-in headless bootstrap"
```

---

### Task 10: Bash tests for `setup_webtrees_bootstrap`

Add tests for: no-op when `WT_ADMIN_USER` unset, fail-fast when `WT_ADMIN_PASSWORD` missing, marker set after successful run, marker-respect on second run, write-config when missing.

End-to-end tests against a real DB live in CI (Task 13). Here we test only the entrypoint logic by stubbing out the `php` calls.

**Files:**
- Modify: `tests/test-entrypoint.sh` (add new tests at the end)

- [ ] **Step 1:** Open `tests/test-entrypoint.sh`. Read the existing helper functions (`mk_vol`, `vol_prep`, `run_entrypoint`, `assert_*`) — Tasks 9/10 use the same patterns.

- [ ] **Step 2:** Add a new helper near the top (after the existing helpers, before any `test_*` functions). This helper stubs the `php` binary inside the container so the entrypoint runs without a real DB.

```bash
# Replace /usr/local/bin/php with a stub that records its argv and returns 0,
# so tests can exercise the bootstrap logic without a real DB connection.
vol_install_php_stub() {
    local vol="$1"
    docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" -c '
        mkdir -p /v/usr/local/bin
        cat > /v/usr/local/bin/php <<EOF
#!/bin/sh
echo "PHP-STUB \$@" >> /var/www/.bootstrap-stub.log
exit 0
EOF
        chmod +x /v/usr/local/bin/php
    ' >/dev/null
}
```

Note: this stub overlays only files inside the volume — the *real* `php` in the image (at `/usr/local/bin/php`) is shadowed when the volume is mounted on `/`. Since we mount the volume on `/var/www` (the seed target) the stub won't actually intercept. Adjust by using a wrapping test that mounts a tmpfs at a known location and uses `PATH` rewriting — see Step 3.

- [ ] **Step 3:** Replace Step 2's approach with a saner one: mount a small directory containing the stub at `/usr/local/bin` via a separate volume + use a custom `PATH`. Here's the actual helper:

```bash
# Build an ephemeral image layer with a php stub, used only for bootstrap
# tests so the entrypoint reaches the bootstrap function without real DB.
build_stub_image() {
    local stub_image="webtrees-bootstrap-stub:test"
    docker build -t "$stub_image" - <<'EOF' >/dev/null
ARG BASE_IMAGE
FROM scratch
EOF
    # Easier path: derive from the test image directly.
    docker build -t "$stub_image" --build-arg "BASE_IMAGE=$IMAGE" - <<EOF >/dev/null
FROM $IMAGE
RUN mv /usr/local/bin/php /usr/local/bin/php.real && \
    cat > /usr/local/bin/php <<'STUB'
#!/bin/sh
echo "PHP-STUB \$*" >> /var/www/.bootstrap-stub.log
exit 0
STUB
    chmod +x /usr/local/bin/php
EOF
    printf '%s' "$stub_image"
}
```

- [ ] **Step 4:** Add the test cases at the end of the file (before the final summary block).

```bash
# ============================================================================
# Bootstrap-Hook tests (setup_webtrees_bootstrap)
# ============================================================================

test_bootstrap_noop_without_admin_user() {
    local name="bootstrap: no-op when WT_ADMIN_USER unset"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)

    # Pre-seed the volume so the seed state machine passes.
    vol_prep "$vol" 'mkdir -p /v/html/public /v/html/data && \
        touch /v/.webtrees-bundled-version && \
        echo "2.2.6" > /v/.webtrees-bundled-version && \
        touch /v/html/public/index.php'

    local out exit
    out=$(docker run --rm \
        -v "$vol:/var/www" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        "${PHP_ENV[@]}" \
        "$stub" \
        /docker-entrypoint.sh php-fpm -t 2>&1) || true
    exit=$?

    if [[ "$exit" -eq 0 ]] && ! echo "$out" | grep -q "PHP-STUB"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — exit=$exit, php-stub-hit=$(echo "$out" | grep -c PHP-STUB)")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_fails_without_password() {
    local name="bootstrap: fails when WT_ADMIN_USER set but password missing"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)

    vol_prep "$vol" 'mkdir -p /v/html/public /v/html/data && \
        echo "2.2.6" > /v/.webtrees-bundled-version && \
        touch /v/html/public/index.php'

    local out exit
    out=$(docker run --rm \
        -v "$vol:/var/www" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        "${PHP_ENV[@]}" \
        "$stub" \
        /docker-entrypoint.sh php-fpm -t 2>&1) || true
    exit=$?

    if [[ "$exit" -ne 0 ]] && echo "$out" | grep -q "WT_ADMIN_PASSWORD is empty"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — expected non-zero exit + 'WT_ADMIN_PASSWORD is empty' in output, got exit=$exit")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_sets_marker_on_success() {
    local name="bootstrap: marker file present after successful run"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)

    vol_prep "$vol" 'mkdir -p /v/html/public /v/html/data && \
        echo "2.2.6" > /v/.webtrees-bundled-version && \
        touch /v/html/public/index.php'

    docker run --rm \
        -v "$vol:/var/www" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        "${PHP_ENV[@]}" \
        "$stub" \
        /docker-entrypoint.sh true >/dev/null 2>&1 || true

    local marker_present
    marker_present=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c '[ -f /v/.webtrees-bootstrapped ] && echo yes || echo no')

    if [[ "$marker_present" == "yes" ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — marker missing after bootstrap")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_respects_marker_on_second_run() {
    local name="bootstrap: skips when marker already exists"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)

    vol_prep "$vol" 'mkdir -p /v/html/public /v/html/data && \
        echo "2.2.6" > /v/.webtrees-bundled-version && \
        touch /v/html/public/index.php && \
        touch /v/.webtrees-bootstrapped'

    local out
    out=$(docker run --rm \
        -v "$vol:/var/www" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        "${PHP_ENV[@]}" \
        "$stub" \
        /docker-entrypoint.sh true 2>&1 || true)

    # The PHP stub logs into /var/www/.bootstrap-stub.log if called.
    local stub_calls
    stub_calls=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null | wc -l')

    if [[ "$stub_calls" -eq 0 ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — bootstrap ran $stub_calls php commands despite marker")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}
```

- [ ] **Step 5:** Wire the new tests into the main test runner. Find the existing test invocations (a sequence like `test_seed_first_run`, `test_seed_marker_mismatch`, etc.) and add:

```bash
test_bootstrap_noop_without_admin_user
test_bootstrap_fails_without_password
test_bootstrap_sets_marker_on_success
test_bootstrap_respects_marker_on_second_run
```

- [ ] **Step 6:** Run the new tests against the Task 9 image.

```bash
TEST_IMAGE=webtrees-php-test:phase1-task9 ./tests/test-entrypoint.sh
```

Expected: all four new tests pass, plus the existing seed tests still pass.

- [ ] **Step 7:** Ready to commit.

```
Task 10 ready to commit:
  git add tests/test-entrypoint.sh
  git commit -m "Add entrypoint tests for setup_webtrees_bootstrap"
```

---

## CI-Erweiterung

### Task 11: Create `dev/nginx-version.json`

Single-entry manifest that drives the nginx image build separately from `dev/versions.json`.

**Files:**
- Create: `dev/nginx-version.json`

- [ ] **Step 1:** Write the file.

```json
{
    "nginx_base": "1.28",
    "config_revision": 1,
    "tag": "1.28-r1"
}
```

- [ ] **Step 2:** Validate JSON.

```bash
docker run --rm -v "$PWD/dev:/d" alpine:3.20 sh -c \
    'apk add --no-cache jq >/dev/null && jq . /d/nginx-version.json >/dev/null'
```

Expected: exit code 0, no output.

- [ ] **Step 3:** Ready to commit.

```
Task 11 ready to commit:
  git add dev/nginx-version.json
  git commit -m "Pin nginx image revision via dev/nginx-version.json"
```

---

### Task 12: Extend `.github/workflows/build.yml` — four targets

Refactor the existing single-target workflow into a multi-target matrix that builds `webtrees-php`, `webtrees-php-full`, and `webtrees-nginx` per `dev/versions.json` entry (php / php-full) or per `nginx-version.json` (nginx).

**Files:**
- Modify: `.github/workflows/build.yml`

- [ ] **Step 1:** Replace the entire content of `.github/workflows/build.yml` with the following.

```yaml
name: Build and push image

# Triggers:
#   workflow_dispatch — run manually; optionally restrict to one webtrees version
#   tag push v*       — for release tags
on:
    workflow_dispatch:
        inputs:
            webtrees_version:
                description: 'Webtrees version (e.g. 2.2.6). Empty = build every entry in dev/versions.json.'
                required: false
                type: string
    push:
        tags:
            - 'v*'

jobs:
    matrix:
        name: Build matrix
        runs-on: ubuntu-latest
        outputs:
            php_entries: ${{ steps.set.outputs.php_entries }}
            nginx_tag: ${{ steps.set.outputs.nginx_tag }}
            nginx_config_revision: ${{ steps.set.outputs.nginx_config_revision }}
        steps:
            - uses: actions/checkout@v4

            - id: set
              run: |
                  set -euo pipefail
                  if [ -n "${{ inputs.webtrees_version }}" ]; then
                      php_entries=$(jq -c "[.[] | select(.webtrees == \"${{ inputs.webtrees_version }}\")]" dev/versions.json)
                      if [ "$php_entries" = "[]" ]; then
                          echo "::error::webtrees ${{ inputs.webtrees_version }} not present in dev/versions.json"
                          exit 1
                      fi
                  else
                      php_entries=$(jq -c . dev/versions.json)
                  fi
                  echo "php_entries=$php_entries" >> "$GITHUB_OUTPUT"
                  echo "nginx_tag=$(jq -r .tag dev/nginx-version.json)" >> "$GITHUB_OUTPUT"
                  echo "nginx_config_revision=$(jq -r .config_revision dev/nginx-version.json)" >> "$GITHUB_OUTPUT"

    build-php:
        name: php ${{ matrix.entry.webtrees }}-${{ matrix.entry.php }}
        needs: matrix
        runs-on: ubuntu-latest
        permissions:
            contents: read
            packages: write
        strategy:
            fail-fast: false
            matrix:
                entry: ${{ fromJson(needs.matrix.outputs.php_entries) }}
        steps:
            - uses: actions/checkout@v4
            - uses: docker/setup-qemu-action@v3
            - uses: docker/setup-buildx-action@v3
            - uses: docker/login-action@v3
              with:
                  registry: ghcr.io
                  username: ${{ github.actor }}
                  password: ${{ secrets.GITHUB_TOKEN }}

            - name: Compute tag list
              id: tags
              run: |
                  set -euo pipefail
                  primary="ghcr.io/magicsunday/webtrees/php:${{ matrix.entry.webtrees }}-php${{ matrix.entry.php }}"
                  tags="$primary"
                  for extra in $(jq -r '.[]' <<<'${{ toJson(matrix.entry.tags) }}'); do
                      tags="$tags,ghcr.io/magicsunday/webtrees/php:$extra"
                  done
                  printf 'tags=%s\n' "$tags" >> "$GITHUB_OUTPUT"

            - uses: docker/build-push-action@v5
              with:
                  context: .
                  file: ./Dockerfile
                  target: php-build
                  push: true
                  platforms: linux/amd64,linux/arm64
                  tags: ${{ steps.tags.outputs.tags }}
                  build-args: |
                      PHP_VERSION=${{ matrix.entry.php }}
                      WEBTREES_VERSION=${{ matrix.entry.webtrees }}
                      VCS_REF=${{ github.sha }}
                      BUILD_DATE=${{ github.event.repository.updated_at }}
                      DOCKER_SERVER=ghcr.io/magicsunday
                  cache-from: type=gha,scope=php-${{ matrix.entry.php }}
                  cache-to: type=gha,mode=max,scope=php-${{ matrix.entry.php }}

    build-php-full:
        name: php-full ${{ matrix.entry.webtrees }}-${{ matrix.entry.php }}
        needs: matrix
        runs-on: ubuntu-latest
        permissions:
            contents: read
            packages: write
        strategy:
            fail-fast: false
            matrix:
                entry: ${{ fromJson(needs.matrix.outputs.php_entries) }}
        steps:
            - uses: actions/checkout@v4
            - uses: docker/setup-qemu-action@v3
            - uses: docker/setup-buildx-action@v3
            - uses: docker/login-action@v3
              with:
                  registry: ghcr.io
                  username: ${{ github.actor }}
                  password: ${{ secrets.GITHUB_TOKEN }}

            - name: Compute tag list
              id: tags
              run: |
                  set -euo pipefail
                  primary="ghcr.io/magicsunday/webtrees/php-full:${{ matrix.entry.webtrees }}-php${{ matrix.entry.php }}"
                  tags="$primary"
                  for extra in $(jq -r '.[]' <<<'${{ toJson(matrix.entry.tags) }}'); do
                      tags="$tags,ghcr.io/magicsunday/webtrees/php-full:$extra"
                  done
                  printf 'tags=%s\n' "$tags" >> "$GITHUB_OUTPUT"

            - uses: docker/build-push-action@v5
              with:
                  context: .
                  file: ./Dockerfile
                  target: php-build-full
                  push: true
                  platforms: linux/amd64,linux/arm64
                  tags: ${{ steps.tags.outputs.tags }}
                  build-args: |
                      PHP_VERSION=${{ matrix.entry.php }}
                      WEBTREES_VERSION=${{ matrix.entry.webtrees }}
                      VCS_REF=${{ github.sha }}
                      BUILD_DATE=${{ github.event.repository.updated_at }}
                      DOCKER_SERVER=ghcr.io/magicsunday
                  cache-from: type=gha,scope=php-full-${{ matrix.entry.php }}
                  cache-to: type=gha,mode=max,scope=php-full-${{ matrix.entry.php }}

    build-nginx:
        name: nginx ${{ needs.matrix.outputs.nginx_tag }}
        needs: matrix
        runs-on: ubuntu-latest
        permissions:
            contents: read
            packages: write
        steps:
            - uses: actions/checkout@v4
            - uses: docker/setup-qemu-action@v3
            - uses: docker/setup-buildx-action@v3
            - uses: docker/login-action@v3
              with:
                  registry: ghcr.io
                  username: ${{ github.actor }}
                  password: ${{ secrets.GITHUB_TOKEN }}

            - uses: docker/build-push-action@v5
              with:
                  context: .
                  file: ./Dockerfile
                  target: nginx-build
                  push: true
                  platforms: linux/amd64,linux/arm64
                  tags: |
                      ghcr.io/magicsunday/webtrees/nginx:${{ needs.matrix.outputs.nginx_tag }}
                      ghcr.io/magicsunday/webtrees/nginx:latest
                  build-args: |
                      NGINX_CONFIG_REVISION=${{ needs.matrix.outputs.nginx_config_revision }}
                      VCS_REF=${{ github.sha }}
                      BUILD_DATE=${{ github.event.repository.updated_at }}
                  cache-from: type=gha,scope=nginx
                  cache-to: type=gha,mode=max,scope=nginx
```

- [ ] **Step 2:** Validate workflow YAML syntax.

```bash
docker run --rm -v "$PWD/.github:/w" pipelinecomponents/yamllint:latest \
    yamllint -d '{extends: relaxed, rules: {line-length: disable}}' /w/workflows/build.yml
```

Expected: exit code 0 (warnings about long lines are fine; errors are not).

- [ ] **Step 3:** Verify the workflow file parses as JSON via GitHub's act tool (optional, if installed locally).

```bash
# Skip if 'act' is not installed locally; the next push to a PR validates remotely.
command -v act >/dev/null 2>&1 && act -W .github/workflows/build.yml --list || true
```

- [ ] **Step 4:** Ready to commit.

```
Task 12 ready to commit:
  git add .github/workflows/build.yml
  git commit -m "Build all four image tracks in CI (php, php-full, nginx)"
```

---

### Task 13: Add smoke-test job to CI

Bring each just-built image up via the repo's `compose.yaml` + `compose.publish.yaml` and curl `/` to confirm the stack actually serves traffic. Edition matrix: `core` (uses `webtrees-php`) and `full` (uses `webtrees-php-full`).

**Files:**
- Modify: `.github/workflows/build.yml` (append smoke-test job)

- [ ] **Step 1:** Append the new job at the end of `.github/workflows/build.yml`.

```yaml
    smoke-test:
        name: smoke ${{ matrix.edition }} ${{ matrix.entry.webtrees }}-${{ matrix.entry.php }}
        needs: [matrix, build-php, build-php-full, build-nginx]
        runs-on: ubuntu-latest
        strategy:
            fail-fast: false
            matrix:
                edition: [core, full]
                entry: ${{ fromJson(needs.matrix.outputs.php_entries) }}
        steps:
            - uses: actions/checkout@v4

            - name: Prepare .env for smoke-test
              run: |
                  set -euo pipefail
                  cat > .env <<EOF
                  COMPOSE_PROJECT_NAME=webtrees-smoke
                  COMPOSE_FILE=compose.yaml:compose.publish.yaml
                  DOCKER_SERVER=ghcr.io/magicsunday
                  PHP_VERSION=${{ matrix.entry.php }}
                  WEBTREES_VERSION=${{ matrix.entry.webtrees }}
                  WEBTREES_NGINX_VERSION=${{ needs.matrix.outputs.nginx_tag }}
                  ENVIRONMENT=production
                  ENFORCE_HTTPS=FALSE
                  APP_PORT=18080
                  MARIADB_ROOT_PASSWORD=smoke-root
                  MARIADB_USER=webtrees
                  MARIADB_PASSWORD=smoke-pw
                  MARIADB_HOST=db
                  MARIADB_DATABASE=webtrees
                  MARIADB_PORT=3306
                  PHP_MAX_EXECUTION_TIME=30
                  PHP_MAX_INPUT_VARS=1000
                  PHP_MEMORY_LIMIT=256M
                  PHP_POST_MAX_SIZE=128M
                  PHP_UPLOAD_MAX_FILESIZE=128M
                  MAIL_SMTP=
                  MAIL_DOMAIN=example.org
                  MAIL_HOST=
                  LOCAL_GROUP_ID=82
                  LOCAL_GROUP_NAME=www-data
                  WEBTREES_TABLE_PREFIX=wt_
                  WEBTREES_REWRITE_URLS=0
                  EOF

                  # Swap to php-full image for the full-edition matrix slot
                  if [ "${{ matrix.edition }}" = "full" ]; then
                      # Override the phpfpm image via compose.override.yaml so the
                      # rest of compose.yaml stays intact.
                      cat > compose.override.yaml <<EOF
                  services:
                      phpfpm:
                          image: ghcr.io/magicsunday/webtrees/php-full:${{ matrix.entry.webtrees }}-php${{ matrix.entry.php }}
                  EOF
                  fi

            - name: Pull images
              run: docker compose pull

            - name: Up stack
              run: docker compose up -d

            - name: Wait for nginx healthy
              run: |
                  set -euo pipefail
                  for i in $(seq 1 60); do
                      health=$(docker compose ps --format json nginx | jq -r '.Health // "starting"' 2>/dev/null || echo starting)
                      if [ "$health" = "healthy" ]; then
                          echo "nginx healthy after ${i}s"
                          exit 0
                      fi
                      sleep 1
                  done
                  echo "::error::nginx did not become healthy within 60s"
                  docker compose logs --tail=200
                  exit 1

            - name: Probe HTTP
              run: |
                  set -euo pipefail
                  response=$(curl -sS http://localhost:18080/)
                  echo "$response" | head -50
                  echo "$response" | grep -qi "webtrees" || {
                      echo "::error::response body does not mention 'webtrees'"
                      exit 1
                  }

            - name: Tear down
              if: always()
              run: docker compose down -v
```

- [ ] **Step 2:** Re-validate the workflow YAML.

```bash
docker run --rm -v "$PWD/.github:/w" pipelinecomponents/yamllint:latest \
    yamllint -d '{extends: relaxed, rules: {line-length: disable}}' /w/workflows/build.yml
```

Expected: exit code 0.

- [ ] **Step 3:** Ready to commit.

```
Task 13 ready to commit:
  git add .github/workflows/build.yml
  git commit -m "Smoke-test stack against newly built images (core + full editions)"
```

---

## End-to-end

### Task 14: Full local end-to-end verification

Bring up the dev stack using the changes from all prior tasks. Test the Admin-Bootstrap-Hook against a real MariaDB. Test the Full-Edition image. Test the override-hook.

**Files:** none (verification only)

- [ ] **Step 1:** Clean slate.

```bash
make down
docker volume rm webtrees_app webtrees_database webtrees_media 2>/dev/null || true
```

- [ ] **Step 2:** Local build of all targets.

```bash
docker build --target php-build \
    --build-arg WEBTREES_VERSION=2.2.6 \
    --build-arg PHP_VERSION=8.3 \
    -t ghcr.io/magicsunday/webtrees/php:2.2.6-php8.3 .

docker build --target php-build-full \
    --build-arg WEBTREES_VERSION=2.2.6 \
    --build-arg PHP_VERSION=8.3 \
    -t ghcr.io/magicsunday/webtrees/php-full:2.2.6-php8.3 .

docker build --target nginx-build \
    --build-arg NGINX_CONFIG_REVISION=1 \
    -t ghcr.io/magicsunday/webtrees/nginx:1.28-r1 .
```

Expected: all three builds succeed.

- [ ] **Step 3:** Bring up core-edition stack with Admin-Bootstrap.

```bash
make disable-dev-mode
cat > /tmp/wt-test.env <<EOF
COMPOSE_PROJECT_NAME=wt-test-core
COMPOSE_FILE=compose.yaml:compose.publish.yaml
DOCKER_SERVER=ghcr.io/magicsunday
PHP_VERSION=8.3
WEBTREES_VERSION=2.2.6
WEBTREES_NGINX_VERSION=1.28-r1
ENVIRONMENT=production
ENFORCE_HTTPS=FALSE
APP_PORT=18080
MARIADB_ROOT_PASSWORD=test-root
MARIADB_USER=webtrees
MARIADB_PASSWORD=test-pw
MARIADB_HOST=db
MARIADB_DATABASE=webtrees
MARIADB_PORT=3306
PHP_MAX_EXECUTION_TIME=30
PHP_MEMORY_LIMIT=256M
PHP_POST_MAX_SIZE=128M
PHP_UPLOAD_MAX_FILESIZE=128M
WT_ADMIN_USER=admin
WT_ADMIN_EMAIL=admin@example.org
WT_ADMIN_PASSWORD=admin12345
EOF

cp /tmp/wt-test.env .env
docker compose up -d
sleep 30
docker compose ps
```

Expected: all services healthy.

- [ ] **Step 4:** Verify bootstrap ran.

```bash
docker compose exec phpfpm cat /var/www/.webtrees-bootstrapped 2>&1 | head -3
docker compose exec phpfpm cat /var/www/html/data/config.ini.php
```

Expected: marker file exists, `config.ini.php` contains the test creds.

- [ ] **Step 5:** Verify admin login.

```bash
curl -c /tmp/wt-cookies.txt -s -o /tmp/wt-login.html http://localhost:18080/login
# Webtrees login form: extract CSRF token, submit creds
# (manual browser test is OK for this step)
```

Open `http://localhost:18080/` in a browser, log in as `admin` / `admin12345`. Expected: lands in webtrees admin dashboard.

- [ ] **Step 6:** Switch to full-edition.

```bash
docker compose down -v
docker volume rm wt-test-core_app wt-test-core_database wt-test-core_media 2>/dev/null || true

cat > compose.override.yaml <<EOF
services:
    phpfpm:
        image: ghcr.io/magicsunday/webtrees/php-full:2.2.6-php8.3
EOF

docker compose up -d
sleep 30
docker compose ps
```

Expected: stack healthy.

- [ ] **Step 7:** Verify Magic-Sunday modules present.

```bash
docker compose exec phpfpm ls /var/www/html/vendor/magicsunday/
```

Expected: `webtrees-fan-chart`, `webtrees-pedigree-chart`, `webtrees-descendants-chart`, `webtrees-statistics` are listed.

Open the webtrees admin → modules page; the Magic-Sunday charts should appear in the list of available modules.

- [ ] **Step 8:** Verify override-hook works.

```bash
mkdir -p /tmp/wt-nginx-custom
cat > /tmp/wt-nginx-custom/upload.conf <<EOF
client_max_body_size 1g;
EOF

cat > compose.override.yaml <<EOF
services:
    phpfpm:
        image: ghcr.io/magicsunday/webtrees/php-full:2.2.6-php8.3
    nginx:
        volumes:
            - /tmp/wt-nginx-custom:/etc/nginx/conf.d/custom:ro
EOF

docker compose up -d nginx
sleep 5
docker compose exec nginx grep -r "client_max_body_size 1g" /etc/nginx/
```

Expected: prints the line from `/etc/nginx/conf.d/custom/upload.conf`.

- [ ] **Step 9:** Tear down and restore your normal dev state.

```bash
docker compose down -v
rm -f compose.override.yaml /tmp/wt-test.env /tmp/wt-cookies.txt /tmp/wt-login.html
rm -rf /tmp/wt-nginx-custom
# Restore your real .env
git checkout .env 2>/dev/null || true
make enable-dev-mode
make up
```

- [ ] **Step 10:** Ready to mark Phase 1 complete.

```
Phase 1 complete. Recap to user:
  - Refactor Dockerfile (php-base + php-build + php-build-full + nginx-build)
  - setup/composer-{core,full}.json split
  - rootfs/etc/nginx/conf.d/default.conf override-hook
  - rootfs/docker-entrypoint.sh setup_webtrees_bootstrap
  - dev/nginx-version.json
  - compose.yaml + compose.development.yaml updated for new nginx image
  - tests/test-entrypoint.sh extended
  - .github/workflows/build.yml builds 4 targets + smoke-tests
```

After user merges all Phase-1 commits to `main`, CI will publish the new images. Phase 2 (Wizard) can start.

---

## Self-Review

**1. Spec coverage:**
- ✅ Dockerfile-Struktur (Sektion 2 in spec) — Tasks 2, 5, 6, 7
- ✅ Edition-Auswahl via expliziter Stages — Tasks 4, 5, 6
- ✅ Composer-full.json mit `replace`-Option falls nötig — Task 4 Step 3 has the fallback
- ✅ Override-Hook (`include /etc/nginx/conf.d/custom/*.conf;`) — Task 7
- ✅ Admin-Bootstrap-Hook im PHP-Image-Entrypoint — Task 9
- ✅ CI Multi-Target — Task 12
- ✅ Smoke-Test über Edition×Versions-Matrix — Task 13
- ✅ Compose.yaml using new nginx image — Task 8
- ✅ `dev/nginx-version.json` — Task 11
- ✅ Tests-Erweiterung für Bootstrap-Hook (Bash, analog `test-entrypoint.sh`) — Task 10
- ⚠ Discovery für Pfad A (offener Implementations-Punkt aus Spec) — Task 1; addendum to spec required
- ⏭ Wizard, Demo-Tree, README-split, scripts/setup.sh deletion → Phase 2/3, not in this plan

**2. Placeholder scan:** Task 9 Step 1 contains two `── PLACEHOLDER ──` markers because the exact CLI verb (`migrate` vs. `db:migrate`) is unknown until Task 1 runs. This is explicitly flagged in the task as "update based on Task 1 findings". Not a plan failure — it's a data dependency.

**3. Type consistency:** The function name `setup_webtrees_bootstrap` is used identically in Task 9 (implementation), Task 9 Step 2 (wire-up), and Task 10 (tests). The marker file `/var/www/.webtrees-bootstrapped` is consistent across Task 9 (write) and Task 10 (test). Image tag schema `webtrees-nginx:1.28-r1` is consistent across Tasks 7, 8 Step 3, 11, 12.

**4. Spec requirements with no task:** none in Phase 1 scope. Demo-tree, wizard, README — explicitly deferred to Phases 2/3.
