# Webtrees Self-Host

Docker images and a wizard for running [webtrees](https://www.webtrees.net/)
without writing your own compose file.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --non-interactive --no-admin --edition full --proxy standalone --port 8080
```

(Or with admin auto-create: drop `--no-admin` and add `--admin-user admin --admin-email me@example.org`.)

The wizard writes `compose.yaml` + `.env` into the current directory and
brings the stack up via `docker compose up -d`. Visit `http://localhost:8080/`.

## Editions

| Edition | Image | Contains |
|---|---|---|
| Core | `webtrees/php` | Plain webtrees release |
| Full (default) | `webtrees/php-full` | + Magic-Sunday charts |
| Full + Demo | same as Full | + a 7-generation synthetic family tree imported on first boot |

`--edition core` / `full` selects between the first two; add `--demo`
to also seed the demo tree.

## Modes

| Mode | Flag | When to use |
|---|---|---|
| Standalone | `--proxy standalone --port <N>` | Single host, no reverse proxy. nginx publishes the chosen port. |
| Traefik | `--proxy traefik --domain <fqdn>` | nginx joins the `traefik` external network and answers under your Traefik router. |

## What the wizard writes

- `compose.yaml` — services, named volumes, healthchecks.
- `.env` — image tags + (standalone) the host port override.
- `.webtrees-admin-password` — only when `--admin-user` is set; mode 0600.

Subsequent `docker compose pull && up -d` re-uses the same files.

## Customising

Drop a `compose.override.yaml` next to the generated `compose.yaml` for
extra PHP limits, custom nginx snippets, an external database, or your
own webtrees modules — Docker Compose merges it automatically. A dedicated
customising guide is planned for the next phase.

## Updating to a new webtrees release

```bash
docker compose down
docker volume rm webtrees_app
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --non-interactive --no-admin --edition full --proxy standalone --port 8080 --force
docker compose pull
docker compose up -d
```

`webtrees_database` and `webtrees_media` survive the upgrade; the
`webtrees_app` volume is re-seeded on first boot.

## Backup

- DB: `docker compose exec db mariadb-dump --all-databases --single-transaction > backup.sql`.
- Media: `docker run --rm -v webtrees_media:/m -v "$PWD":/host alpine tar -C /m -czf /host/media.tar.gz .`.

## Troubleshooting

- **Port already in use** — the wizard probes the requested port and falls back to 8080 automatically.
- **`docker compose pull` fails** — confirm GHCR is reachable (`docker pull ghcr.io/magicsunday/webtrees/nginx:1.28-r1`) and re-run.
- **Admin login fails** — the password lives in `.webtrees-admin-password` and was printed once when the wizard finished.

## For module developers

Module developers run the wizard in `--mode dev` against a `git clone`
of this repo:

```bash
git clone https://github.com/magicsunday/webtrees-docker.git
cd webtrees-docker
docker run --rm -it \
  -v "$PWD:/work" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/magicsunday/webtrees/installer:latest --mode dev
```

The dev flow writes a `.env` with the compose chain that bind-mounts
`./app` into phpfpm and brings in buildbox + xdebug + phpMyAdmin.

## License

MIT — see [LICENSE](LICENSE).
