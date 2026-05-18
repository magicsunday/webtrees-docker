# DIY: bring-your-own-compose stack

The wizard renders a working `compose.yaml` for the common standalone
and Traefik scenarios, plus the three BYOD escape hatches
(`--use-external-db`, `--db-data-path`, `--reuse-volumes`) documented
in [`byod.md`](byod.md). For operators who want to consume the project's
images directly — assembling their own `compose.yaml` (or Helm /
Kustomize / Portainer template / GitOps repo) without touching the
wizard at all — this file documents the contract.

When to read this file:

- You already have a curated compose stack and want to add webtrees as
  one service among many.
- You're deploying to Kubernetes via the published OCI images.
- The wizard's defaults conflict with site-specific concerns (custom
  networks, secrets backend, exotic volume drivers).
- You're integrating into a Portainer-managed stack where the
  rendered compose isn't desired.

For everything else, the wizard is the supported entry point — see
[`README.md`](../README.md).

## Images

All four images live on GHCR:

| Image | Purpose |
|---|---|
| `ghcr.io/magicsunday/webtrees-php` | PHP-FPM runtime, **core edition** (vanilla webtrees release). |
| `ghcr.io/magicsunday/webtrees-php-full` | PHP-FPM runtime, **full edition** (release + custom-module bundle from `setup/composer-full.json`). |
| `ghcr.io/magicsunday/webtrees-nginx` | nginx with the project's vhost + trust-proxy map. Reverse-proxies php-fpm. |
| `ghcr.io/magicsunday/webtrees-installer` | The wizard itself. Not used by a DIY stack — listed for completeness. |

Tag shape: `<webtrees-version>-php<php-version>` for the two php
images (e.g. `2.2.6-php8.3`), plain semver for nginx
(e.g. `1.30-r1`), `latest` available on all four. The full matrix
lives in [`dev/versions.json`](../dev/versions.json); the
versioned-tag set is the same one the wizard pins.

Both arches (`linux/amd64`, `linux/arm64`) are published natively on
every tag (#127), so `docker pull` picks the right manifest entry.

## Contract: required environment per service

The authoritative table — every variable, default, consumer file — is
[`env-vars.md`](env-vars.md). The subset below covers what a runtime
DIY stack MUST set (the wizard sets these automatically; DIY ships
them explicitly).

### `phpfpm` (image: `ghcr.io/magicsunday/webtrees-php[-full]`)

| Variable | Required | Purpose |
|---|---|---|
| `WEBTREES_VERSION` | yes | Image-baked version. On boot the entrypoint compares this string against the `app:` volume's marker file. A mismatch logs a warning and continues — the value drives the seed state machine, it is not an authorisation check. |
| `WEBTREES_AUTO_SEED` | no (default `false`) | When `true`, first boot extracts `/var/www/html` from the image into the `app:` volume. Required only for the very first boot; subsequent boots short-circuit via the marker file. |
| `MARIADB_HOST` | no (default `db`) | Hostname of the MariaDB / MySQL server (compose service name for bundled, FQDN/IP for external). The default matches the bundled-DB service name; set it when your stack deviates. |
| `MARIADB_USER` | no (default `webtrees`) | DB user webtrees connects as. |
| `MARIADB_DATABASE` | no (default `webtrees`) | Database name. The image does NOT run `CREATE DATABASE` — pre-create it. |
| `MARIADB_PASSWORD_FILE` | yes | Path inside the container to a file containing the password. One trailing newline is tolerated; embedded newlines are preserved. Use this in preference to `MARIADB_PASSWORD` so the secret never enters the process environment. |
| `MARIADB_PORT` | no (default `3306`) | Override for non-standard ports. |
| `ENFORCE_HTTPS` | no (default `FALSE`) | When `TRUE`, webtrees emits 301 redirects from http to https. Trust gate via `X-Forwarded-Proto: https` from a trusted proxy. |
| `ENVIRONMENT` | no (default `production`) | Sets webtrees' debug behaviour. Use `development` only behind firewalls. |
| `WEBTREES_REWRITE_URLS` | no (default `0`) | `1` activates webtrees' pretty-URLs feature. **Effective only on the headless-bootstrap path** (when `WT_ADMIN_USER` is set); operators relying on webtrees' browser setup wizard configure pretty-URLs in the UI instead. |

Headless admin-bootstrap (writes `config.ini.php`, runs the schema
migration, creates an admin user — wizard-default behaviour). Setting
`WT_ADMIN_USER` is the **switch** that turns the headless bootstrap
on; leave it unset to let webtrees' own browser-based setup wizard
take over after first boot.

| Variable | Required | Purpose |
|---|---|---|
| `WT_ADMIN_USER` | optional | Username for the first admin account. Setting this also enables the headless config.ini.php + schema-migration chain — without it the entrypoint does only the seed step and SMTP rows, deferring DB schema setup to the browser wizard. |
| `WT_ADMIN_EMAIL` | optional | Email for the first admin account. |
| `WT_ADMIN_PASSWORD_FILE` | optional | Path inside the container to a file containing the admin password. One trailing newline is tolerated. |

Optional SMTP — covered in full in `env-vars.md` under the `WT_SMTP_*`
prefix. Set `WT_SMTP_HOST` to activate; the entrypoint writes the
corresponding rows into webtrees' `site_setting` table on first boot.

### `nginx` (image: `ghcr.io/magicsunday/webtrees-nginx`)

| Variable | Required | Purpose |
|---|---|---|
| `ENFORCE_HTTPS` | no (default `FALSE`) | Matches the `phpfpm` setting; nginx redirects http → https when `TRUE` and the request did not arrive with `X-Forwarded-Proto: https`. |
| `NGINX_TRUSTED_PROXIES` | conditional | CIDR list of upstream proxies whose `X-Forwarded-Proto` header may be trusted. Required if the stack sits behind a reverse proxy / load balancer; leave unset for direct-publish stacks. See [`https-certs.md`](https-certs.md) for the trust-gate behaviour. |

### MariaDB (image: `mariadb:11.8` or operator-chosen)

The project does not publish a custom MariaDB image — any compatible
mariadb / mysql tag works. The wizard's choice is `mariadb:11.8` (see
`dev/versions.json` if you want the pinned tag).

## Volumes

The `phpfpm` and `nginx` containers expect three logical volumes; the
nginx side only mounts the read-only views.

| Volume | Mounted at (phpfpm) | Mounted at (nginx) | Purpose |
|---|---|---|---|
| `app` | `/var/www/html` (rw) | `/var/www/html` (ro) | Webtrees code + `data/config.ini.php` + tree cache. Seeded on first boot from the image; preserve across upgrades. |
| `media` | `/var/www/html/data/media` (rw) | `/var/www/html/data/media` (ro) | User-uploaded images / GEDCOM media. Persistent across the entire install lifetime. |
| `secrets` | `/secrets` (ro) | — | Files holding DB password, admin password, etc. Generated by the wizard's `init` service; a DIY stack provides them directly (one file per secret, mode 0444 recommended). |

The `app:` volume is internal-state-only — never bind-mount a host
directory there unless you understand the seed-vs-upgrade dance the
entrypoint runs.

## Healthchecks

The published images do NOT carry built-in `HEALTHCHECK` directives
(deliberate — operators wire them at compose level so the probe
script is visible to the operator). Wire one yourself:

```yaml
phpfpm:
    healthcheck:
        test: ["CMD-SHELL", "pgrep php-fpm > /dev/null || exit 1"]
        interval: 5s
        timeout: 3s
        retries: 3
        # 45s grace: the entrypoint runs seed + config-ini + schema
        # migrate + (optional) admin-bootstrap before php-fpm execs.
        start_period: 45s

nginx:
    healthcheck:
        test: ["CMD-SHELL", "curl -sf -H 'X-Forwarded-Proto: https' 'http://localhost/index.php?route=/login' -o /dev/null || exit 1"]
        interval: 10s
        timeout: 5s
        retries: 3
        # 60s grace: covers cold-cache first boot on NAS hardware.
        start_period: 60s
```

The `X-Forwarded-Proto: https` header in the nginx probe bypasses the
`ENFORCE_HTTPS=TRUE` redirect. Without it, nginx emits a 301 to
`https://localhost:443`. `curl -sf` does NOT follow redirects (no
`-L`) and treats 3xx as success — the probe would exit 0, masking
the redirect loop instead of detecting it. The header tells nginx
that the upstream already terminated TLS so a 200 comes back
directly. Drop the header only if `ENFORCE_HTTPS` is `FALSE`.

## Trusted-proxy / X-Forwarded-* handling

The nginx image carries a `geo` map that decides which client's
`X-Forwarded-Proto` header is trusted. By default no upstream is
trusted, so direct-publish stacks work out of the box.

Behind a reverse proxy / load balancer, set
`NGINX_TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` (or
the specific CIDR of your proxy). Wildcards like `0.0.0.0/0` are
explicitly rejected at startup — the trust gate refuses to trust
everyone. Full reasoning in [`https-certs.md`](https-certs.md).

## First-boot seed

What the `phpfpm` entrypoint actually does on each boot, in order
(call sequence from `main()` in `rootfs/docker-entrypoint.sh`):

1. **Seed** (gated on `WEBTREES_AUTO_SEED=true`): unpack
   `/var/www/html` from the image into the `app:` volume and record
   the version in the marker file
   `/var/www/html/.webtrees-bundled-version`. A second boot whose
   marker matches `WEBTREES_VERSION` short-circuits this step; a
   mismatch logs a warning and continues so the operator can decide
   whether to wipe the volume.
2. **Headless bootstrap** (gated on `WT_ADMIN_USER` being set):
   write `data/config.ini.php` from the `MARIADB_*` envs, run the
   webtrees schema migration CLI, and create the admin account with
   Argon2id hashing of the password from `WT_ADMIN_PASSWORD_FILE`.
   Without `WT_ADMIN_USER` this entire step is a no-op — webtrees'
   built-in browser setup wizard takes over for the schema + admin
   creation.
3. **SMTP rows** (gated on `WT_SMTP_HOST` being set, AND on
   `data/config.ini.php` existing): write the `WT_SMTP_*` values
   into webtrees' `site_setting` table. On the headless-bootstrap
   path config.ini.php already exists from step 2, so SMTP rows
   land on first boot. On the browser-setup path config.ini.php
   doesn't exist until the operator finishes the wizard, so the
   first SMTP write is deferred to the boot AFTER that — the
   `WT_SMTP_HOST` env can be present from day one without error.

To force a fresh seed (e.g. after a catastrophic data loss), wipe
the `app:` volume entirely. The marker file controls the seed
state machine; deleting only the marker without wiping the volume
puts the entrypoint into an ambiguous state.

## Minimal hand-written compose example

A working standalone DIY stack — no wizard, no Jinja, plain YAML.
Adjust to taste. Create the `secrets/` directory next to this file
before `docker compose up`.

```yaml
volumes:
    app:
    media:
    database:

services:
    db:
        image: mariadb:11.8
        restart: unless-stopped
        environment:
            MARIADB_ROOT_PASSWORD_FILE: /run/secrets/mariadb_root
            MARIADB_USER: webtrees
            MARIADB_PASSWORD_FILE: /run/secrets/mariadb_user
            MARIADB_DATABASE: webtrees
        volumes:
            - database:/var/lib/mysql
        secrets:
            - mariadb_root
            - mariadb_user
        healthcheck:
            test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

    phpfpm:
        image: ghcr.io/magicsunday/webtrees-php:2.2.6-php8.3
        depends_on:
            db:
                condition: service_healthy
        restart: unless-stopped
        environment:
            WEBTREES_VERSION: "2.2.6"
            WEBTREES_AUTO_SEED: "true"
            MARIADB_HOST: db
            MARIADB_USER: webtrees
            MARIADB_PASSWORD_FILE: /run/secrets/mariadb_user
            MARIADB_DATABASE: webtrees
        volumes:
            - app:/var/www/html
            - media:/var/www/html/data/media
        secrets:
            - mariadb_user
        healthcheck:
            test: ["CMD-SHELL", "pgrep php-fpm > /dev/null || exit 1"]
            interval: 5s
            timeout: 3s
            retries: 3
            start_period: 45s

    nginx:
        image: ghcr.io/magicsunday/webtrees-nginx:1.30-r1
        depends_on:
            phpfpm:
                condition: service_healthy
        restart: unless-stopped
        ports:
            - "8080:80"
        volumes:
            - app:/var/www/html:ro
            - media:/var/www/html/data/media:ro
        healthcheck:
            test: ["CMD-SHELL", "curl -sf -H 'X-Forwarded-Proto: https' 'http://localhost/index.php?route=/login' -o /dev/null || exit 1"]
            interval: 10s
            timeout: 5s
            retries: 3
            start_period: 60s

secrets:
    mariadb_root:
        file: ./secrets/mariadb_root
    mariadb_user:
        file: ./secrets/mariadb_user
```

Bring it up with:

```bash
mkdir -p secrets
openssl rand -hex 24 | tr -d '\n' > secrets/mariadb_root
openssl rand -hex 24 | tr -d '\n' > secrets/mariadb_user
chmod 0400 secrets/*
docker compose up -d
```

The compose `secrets:` mechanism mounts each file under
`/run/secrets/<name>` inside the container; `MARIADB_PASSWORD_FILE`
points at that path. No password ever lives in an environment
variable or in the YAML.

After the stack is healthy, webtrees is reachable at
`http://<host>:8080/`. Pretty-URLs (`WEBTREES_REWRITE_URLS=1`),
HTTPS termination, admin bootstrap, SMTP, BYOD external-db etc. all
map to the variables in [`env-vars.md`](env-vars.md).

## Cross-references

- [`env-vars.md`](env-vars.md) — authoritative env-var inventory.
- [`byod.md`](byod.md) — wizard-driven BYOD patterns
  (`--use-external-db`, `--db-data-path`, `--reuse-volumes`).
- [`https-certs.md`](https-certs.md) — TLS / trusted-proxy details.
- [`maintenance.md`](maintenance.md) — version-upgrade procedure.
- [`../README.md`](../README.md) — wizard-driven install (the
  supported default path).
