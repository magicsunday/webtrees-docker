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

To run against an existing MariaDB / MySQL server in either standalone
or dev mode, pass the `--use-external-db` family on the install
command line. The wizard drops the bundled `db` service entirely,
bind-mounts your operator-supplied password file into phpfpm, and
runs a TCP-reachability probe before render so an unreachable host
fails fast. Full walk-through with `GRANT` snippet, all five flags
and the failure-modes table: [`byod.md`](byod.md).

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
| `ENFORCE_HTTPS` | `TRUE` forces HTTPS redirects in nginx + webtrees. Fresh wizard installs default to `TRUE`; pass `--no-https` (standalone proxy mode only) for `FALSE`. The wizard rejects `--no-https --proxy traefik` because the rendered Traefik router still terminates TLS at the edge. Runtime fallback when the key is unset is `FALSE`. See the **HTTPS trust gate** section below for which proxies are allowed to flip the redirect off via `X-Forwarded-Proto`. Cert provisioning itself is a separate concern — see [`https-certs.md`](https-certs.md). Flipping the value post-install: run `make switch-https` (or `make switch-http`) from the install directory — see below. |
| `WEBTREES_VERSION` | Pins the webtrees image tag. The wizard writes this; bump it manually for an out-of-cycle upgrade. |
| `EXTERNAL_DB_*` | Five-key set (`HOST`, `PORT`, `NAME`, `USER`, `PASSWORD_FILE`) populated when the install was run with `--use-external-db`. The bundled `db` service is dropped from `compose.yaml`; phpfpm reads these via `${EXTERNAL_DB_*}` substitution. See [`byod.md`](byod.md). |
| `APP_PORT` | Host port published by the standalone overlay (default `28080` — the 28k range stays out of the 80/8080 drive-by-scan band; override with `--port`). |
| `WEBTREES_REWRITE_URLS` | `1` enables webtrees pretty URLs (`/tree/.../individual/...` instead of `?route=...`); `0` keeps query-string routing. The wizard wires this from `--pretty-urls`. The entrypoint applies it on first boot only (gated on the `.webtrees-bootstrapped` marker inside the app volume); webtrees has no admin-UI toggle for `rewrite_urls`. To flip the value post-install, run `docker compose exec phpfpm php /var/www/html/public/index.php config-ini --rewrite-urls` (or `--no-rewrite-urls`) — the same CLI the entrypoint invokes. |
| `MARIADB_HOST` / `MARIADB_PORT` | Override when you point at an external database (see above). |

### Switching HTTPS on or off after install

The end-user Makefile ships two targets that flip `ENFORCE_HTTPS` in
your `.env` and restart the two services that read it (nginx for the
301 redirect, phpfpm for HSTS / cookie-secure flags). Volumes — and
therefore database, media, and the webtrees install itself — survive
the restart.

```bash
make switch-https     # first-time HTTP install → HTTPS
make switch-http      # rollback to plain HTTP
```

Both targets are idempotent (running `switch-https` twice is a no-op)
and refuse loud if `.env` is missing — they only operate on a
wizard-rendered install, not a hand-rolled compose stack. For the
hand-rolled case, edit `ENFORCE_HTTPS` in your own `.env` and run
`docker compose up -d --force-recreate --no-deps nginx phpfpm`
yourself — the Makefile targets only encode that exact sequence.

When switching to HTTPS, make sure your reverse proxy (Traefik / Caddy
/ nginx-on-host) is already terminating TLS — the webtrees stack
itself doesn't provision certs. See [`https-certs.md`](https-certs.md)
for the Traefik + ACME and bring-your-own-cert workflows.
The HTTPS trust gate below explains which proxies are allowed to
forward `X-Forwarded-Proto: https` and skip the in-container 301
redirect.

### HTTPS trust gate

With `ENFORCE_HTTPS=TRUE`, nginx normally issues a 301 redirect from
HTTP to HTTPS. A reverse proxy (Traefik, Caddy, nginx-on-host,
Cloudflare tunnel, …) that has already terminated TLS can short-circuit
the redirect by forwarding `X-Forwarded-Proto: https`. To prevent any
client on the LAN from spoofing that header against a directly-reachable
nginx port, the gate trusts the header only from a fixed CIDR set:

| Trusted by default | Why |
|---|---|
| `127.0.0.0/8`, `::1/128` | Local probes inside the container (healthcheck). |
| `172.16.0.0/12` | Docker's default user-bridge range — compose projects, the bundled Traefik overlay. |
| `fc00::/7` | IPv6 ULA, the range Docker uses for IPv6 networks. |

`10.0.0.0/8` and `192.168.0.0/16` are intentionally **not** in default
trust: these are common home/office LAN ranges, so trusting them would
re-open the spoof path whenever nginx is published onto a LAN-reachable
port.

If your reverse proxy lives on a custom Docker network outside
`172.16.0.0/12` (e.g. `--subnet=10.42.0.0/16`), the redirect will fire
for every request and the browser will loop. Set `NGINX_TRUSTED_PROXIES`
to extend the trust set:

```dotenv
# .env or compose env block
NGINX_TRUSTED_PROXIES=10.42.0.0/16
# multiple CIDRs:
NGINX_TRUSTED_PROXIES=10.42.0.0/16,192.168.10.0/24
```

The entrypoint rewrites
`/etc/nginx/includes/trust-proxy-extra.conf` on every container start
into a second `geo` block whose CIDRs are OR-merged with the baked
defaults into `$trusted_proxy`. Hard rules enforced by the entrypoint
(fail-closed — startup aborts loudly on violation):

| Refusal | Why |
|---|---|
| Value longer than 4 KiB or more than 256 entries | DoS shield against a copy-paste accident or a compromised env source. |
| Characters outside `[0-9a-fA-F.:/,\s]` | nginx-directive injection vector — a newline inside one comma chunk could otherwise inject `default 1;` into the geo block and trust every client. |
| Wildcard CIDR (`0.0.0.0/0`, `::/0`, anything ending in `/0`) | Trusts every client, defeating the gate. |
| Prefix length outside `/0..32` (IPv4) or `/0..128` (IPv6) | nginx would refuse the rendered config anyway; failing here surfaces a clear entrypoint error. |
| `nginx -t` failure on the rendered file | Duplicate CIDR, garbled IPv6 form, or any other late-stage rejection is attributed to this script, not to an opaque master-process crash. |

If you need to *remove* one of the baked default CIDRs (rare — operators
on networks colliding with `172.16.0.0/12` who can't move) the env var
is insufficient because the design is additive. Bind-mount a
replacement `trust-proxy-map.conf` instead:

```yaml
services:
  nginx:
    volumes:
      - ./trust-proxy-map.conf:/etc/nginx/includes/trust-proxy-map.conf:ro
```

Move the reverse proxy onto a network in `172.16.0.0/12` as a third
option — `docker network create traefik` without `--subnet` uses the
default pool.

**Sibling-container caveat:** the trust set covers `172.16.0.0/12`, which
is the entire Docker user-bridge range. Every container in the same
compose project (or any other container the operator runs in the same
docker network) shares that range and is therefore trusted by the gate.
A backup sidecar, an exporter, a third-party plugin image, or anything
pulled by an auto-updater can issue `curl -H 'X-Forwarded-Proto: https'
http://nginx/` and reach PHP-FPM with `HTTPS=on` even when no real TLS
termination happened. This is an inherent docker-network trust boundary,
not something the gate can close — treat every sibling container as
having the same secrets nginx serves. The bundled Traefik overlay is the
intended trusted peer; audit anything else you add to the stack.

**Userland-proxy caveat:** when Docker runs in legacy `userland-proxy`
mode (the default on Docker Desktop and some non-iptables Linux setups),
inbound traffic to a published port is SNAT-rewritten to the docker
bridge gateway (e.g. `172.17.0.1`). nginx then sees a trusted source IP
for every external request, and the trust gate cannot distinguish a
legitimate Traefik forward from a LAN attacker's spoofed header. The
mitigation is to switch Docker to `userland-proxy=false` so iptables DNAT
preserves the real client IP — standard on Linux Docker Engine; needs an
explicit `daemon.json` setting on Docker Desktop.

### Wizard state

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
