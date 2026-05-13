# Customising your webtrees stack

This guide is for self-hosters who want to tweak the stack the wizard
generated. Maintainers working on the wizard, the images, or the compose
chain itself should read [`docs/developing.md`](developing.md) instead.

## `compose.override.yaml`

Docker Compose automatically merges a file named `compose.override.yaml`
sitting next to `compose.yaml`. Put every per-host customisation there:
extra services, environment overrides, volume bind-mounts, anything you
do not want to re-do after the next wizard run.

The wizard's `--force` flag overwrites `compose.yaml` and `.env`, but it
never touches `compose.override.yaml`. The same goes for any extra
files you add (custom nginx snippets, secrets, helper scripts).

### Higher PHP limits

The `phpfpm` entrypoint reads `PHP_MEMORY_LIMIT`, `PHP_POST_MAX_SIZE`,
`PHP_UPLOAD_MAX_FILESIZE`, `PHP_MAX_EXECUTION_TIME` and
`PHP_MAX_INPUT_VARS`. The wizard ships sensible defaults (128 MB memory,
128 MB up/post); bump them when a large GEDCOM or a chunky media import
needs more headroom.

```yaml
services:
    phpfpm:
        environment:
            PHP_MEMORY_LIMIT: 512M
            PHP_POST_MAX_SIZE: 256M
            PHP_UPLOAD_MAX_FILESIZE: 256M
            PHP_MAX_EXECUTION_TIME: "120"
```

### Custom nginx snippet

The bundled nginx image includes
`include /etc/nginx/conf.d/custom/*.conf;` inside the `server { }`
block. Drop your own `.conf` files into that directory to add headers,
rewrites, locations, rate limits — anything `nginx -t` accepts.

```yaml
services:
    nginx:
        volumes:
            - ./nginx/security-headers.conf:/etc/nginx/conf.d/custom/security-headers.conf:ro
```

A minimal `nginx/security-headers.conf`:

```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

### External database

To run against an existing MariaDB / MySQL server, disable the bundled
`db` service and point `phpfpm` at the external host. Pair this with
`--use-external-db` (and `--mariadb-host …`) on the wizard command line
when you are in `--mode dev` so the rendered `.env` already wires up
the right `MARIADB_HOST`.

```yaml
services:
    db:
        deploy:
            replicas: 0
    phpfpm:
        environment:
            MARIADB_HOST: db.example.org
            MARIADB_PORT: "3306"
            MARIADB_DATABASE: webtrees
            MARIADB_USER: webtrees
            MARIADB_PASSWORD: ${MARIADB_PASSWORD}
```

### Your own webtrees modules

Webtrees discovers custom modules under
`/var/www/html/vendor/fisharebest/webtrees/modules_v4/`. Bind-mount a
host directory there to drop modules in without rebuilding the image.
Modules added this way survive image upgrades (the `app` volume is
re-seeded on a `WEBTREES_VERSION` bump; a bind-mount is not).

```yaml
services:
    phpfpm:
        volumes:
            - ./modules:/var/www/html/vendor/fisharebest/webtrees/modules_v4
    nginx:
        volumes:
            - ./modules:/var/www/html/vendor/fisharebest/webtrees/modules_v4:ro
```

The `full` edition's image already bundles the Magic-Sunday charts under
that path. A bind-mount fully shadows the directory, so when you go
this route you become responsible for shipping every module yourself —
including the ones the image used to provide.

## Backup

### Daily snapshot

```bash
# Database (single transaction, no table locks). The bundled `db`
# service authenticates root from /secrets/mariadb_root_password,
# which is mounted read-only inside the container — so the dump must
# read the password from there rather than relying on socket auth.
docker compose exec -T db sh -c \
    'mariadb-dump -uroot -p"$(cat /secrets/mariadb_root_password)" \
        --all-databases --single-transaction --quick' \
    | gzip > "backup-$(date +%F).sql.gz"

# Media files (read-only mount, host writes the tarball).
# Substitute "$(basename "$PWD")_media" for the volume name in any
# other install directory — compose derives the project from the cwd.
docker run --rm \
    -v "$(basename "$PWD")_media:/m:ro" \
    -v "$PWD:/host" \
    alpine:3.23 \
    tar -C /m -czf "/host/media-$(date +%F).tar.gz" .
```

The wizard names volumes `<project>_database`, `<project>_media` and
`<project>_app`, where `<project>` is the cwd basename (`webtrees` for
the canonical install path). Only `<project>_media` and the SQL dump
need a backup — `<project>_app` is re-seeded from the image on every
fresh boot.

### Restore

```bash
# Database (same secret-file dance as the backup direction)
gunzip < backup-2026-05-12.sql.gz \
    | docker compose exec -T db sh -c \
        'mariadb -uroot -p"$(cat /secrets/mariadb_root_password)"'

# Media
docker run --rm \
    -v "$(basename "$PWD")_media:/m" \
    -v "$PWD:/host" \
    alpine:3.23 \
    sh -c "cd /m && tar -xzf /host/media-2026-05-12.tar.gz"
```

Bring the stack down before a restore (`docker compose down`) so
webtrees does not see a half-imported database.

### Scheduling

A simple cron entry wrapping a shell script keeps things sustainable.
Drop a `backup.sh` next to your `compose.yaml`, then:

```cron
# Daily at 03:30, prune snapshots older than 14 days
30 3 * * *  cd /srv/webtrees && ./backup.sh >> backup.log 2>&1
```

systemd `OnCalendar=daily` timers work just as well; pick whichever
fits the host. Either way, store the resulting tarballs off the
machine — a backup on the same disk as the live data is not a backup.

## Per-environment configuration

A handful of variables are read straight out of `.env` at compose time
rather than written by the wizard. Add them by hand when you need them:

| Variable | Purpose |
|---|---|
| `ENFORCE_HTTPS` | `TRUE` forces HTTPS redirects in nginx + webtrees. Fresh wizard installs default to `TRUE`; pass `--no-https` to roll an install with `FALSE`. The runtime fallback when the key is unset entirely is `FALSE`. Cert provisioning itself (Let's Encrypt, bring-your-own) is a separate concern — see issue #44 for that workflow. |
| `WEBTREES_VERSION` | Pins the webtrees image tag. The wizard writes this; bump it manually for an out-of-cycle upgrade. |
| `APP_PORT` | Host port published by the standalone overlay (default `28080` — the 28k range stays out of the 80/8080 drive-by-scan band; override with `--port`). |
| `WEBTREES_REWRITE_URLS` | `1` enables webtrees pretty URLs (`/tree/.../individual/...` instead of `?route=...`); `0` keeps query-string routing. The wizard wires this from `--pretty-urls`. The entrypoint applies it on first boot only (gated on the `.webtrees-bootstrapped` marker inside the app volume); webtrees has no admin-UI toggle for `rewrite_urls`. To flip the value post-install, run `docker compose exec phpfpm php /var/www/html/public/index.php config-ini --rewrite-urls` (or `--no-rewrite-urls`) — the same CLI the entrypoint invokes. |
| `MARIADB_HOST` / `MARIADB_PORT` | Override when you point at an external database (see above). |

The wizard's `.env` carries a comment block noting that subsequent runs
ignore the file — edits stick.

If you skip the wizard entirely, your hand-roll reference is the
repo-root `.env.dist`. Each variable carries an inline comment with
its default; you'll see dev-only and proxy-only scopes flagged where
they apply. For an at-a-glance map (every variable → consumer file →
default + any naming collisions worth knowing) see
[`docs/env-vars.md`](env-vars.md).

## When things go wrong

- **Stack stays unhealthy** — `docker compose logs phpfpm` and
  `docker compose logs nginx` surface bad config almost immediately;
  the `db` container's first boot takes 30-60 s before it reports
  healthy.
- **Admin password lost** — the wizard prints it once in the install
  banner and does not save it to disk. Reset via the webtrees CLI
  inside the container:
  `docker compose exec phpfpm php /var/www/html/index.php user-password admin newpass`.
- **Override not picked up** — Compose only merges
  `compose.override.yaml` when the filename matches exactly. Check
  `docker compose config` to see the effective merged stack.
