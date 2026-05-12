# Webtrees Self-Host

Docker images and a wizard for running [webtrees](https://www.webtrees.net/)
without writing your own compose file.

## Before you start

You need a host with Docker Engine installed:

- **Linux**: follow <https://docs.docker.com/engine/install/> for your distro
  (Ubuntu/Debian/Fedora/Arch all supported). Add your user to the `docker`
  group so you can run `docker` without `sudo`.
- **Synology / Ugreen / NAS**: install the Docker / Container Manager
  package from your NAS app store. The wizard binds the docker socket
  at `/var/run/docker.sock` — make sure that's reachable.
- **Docker Desktop (Mac / Windows)**: works for trying it out, but for
  production self-hosting we recommend Linux on a small VPS or NAS.

Verify with `docker version` — you should see both Client and Server
sections without errors.

That's all. The wizard takes care of the rest — no PHP, MariaDB, or
nginx to install yourself.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --non-interactive --no-admin --edition full --proxy standalone --port 8080
```

(Or with admin auto-create: drop `--no-admin` and add `--admin-user admin --admin-email me@example.org`.)

The wizard writes `compose.yaml` + `.env` into the current directory and
brings the stack up via `docker compose up -d`. Visit `http://localhost:8080/`.

When you run the one-liner, the wizard:

1. Pulls the wizard image (~30 MB, one-time).
2. Renders `compose.yaml` and `.env` into your current directory.
3. Pulls the application images (~600 MB total, one-time).
4. Starts the stack via `docker compose up -d`.
5. Prints the URL plus admin credentials (if you chose `--admin-user`).

Total first-run time: ~2 minutes on a 100 Mbit link, less on subsequent runs.

After the wizard finishes, your stack is reachable at the URL it printed.
The first time you visit, webtrees runs its own setup wizard (or auto-
provisions if you passed `--admin-user`).

## Editions

| Edition | Image | Contains |
|---|---|---|
| Core | `webtrees/php` | Plain webtrees release |
| Full (default) | `webtrees/php-full` | + Magic-Sunday charts: [fan](https://github.com/magicsunday/webtrees-fan-chart), [pedigree](https://github.com/magicsunday/webtrees-pedigree-chart), [descendants](https://github.com/magicsunday/webtrees-descendants-chart) |
| Full + Demo | same as Full | + a 7-generation synthetic family tree imported on first boot |

`--edition core` / `full` selects between the first two; add `--demo`
to also seed the demo tree.

## Modes

| Mode | Flag | When to use |
|---|---|---|
| Standalone | `--proxy standalone --port <N>` | Single host, no reverse proxy. nginx publishes the chosen port. |
| Traefik | `--proxy traefik --domain <fqdn>` | nginx joins the `traefik` external network and answers under your Traefik router. |

## Glossary

- **Stack** — a set of containers that run together. Yours has four
  services: `db` (MariaDB), `phpfpm` (webtrees + PHP), `nginx` (web server),
  and `init` (one-shot password-seeding).
- **`compose.yaml`** — the file that describes your stack. The wizard
  writes it for you; you don't usually edit it.
- **`.env`** — key=value pairs that `compose.yaml` reads. Edit this if you
  want to change ports, image tags, etc.
- **`compose.override.yaml`** — your own additions to the stack (e.g. PHP
  limits, custom nginx snippets). See `docs/customizing.md`.
- **Named volumes** — Docker-managed storage that survives container
  restarts. Your stack has `webtrees_database`, `webtrees_media`,
  `webtrees_app`, `webtrees_secrets`.
- **GHCR** — GitHub Container Registry. All images are pulled from
  `ghcr.io/magicsunday/webtrees/...`.

## What the wizard writes

- `compose.yaml` — services, named volumes, healthchecks.
- `.env` — image tags + (standalone) the host port override.
- `.webtrees-admin-password` — only when `--admin-user` is set; mode 0600.

Subsequent `docker compose pull && up -d` re-uses the same files.

## What gets installed where

Your current directory after the wizard runs:

```text
.
├── compose.yaml          # generated; do not edit directly
├── .env                  # generated; image tags + ports live here
├── .webtrees-admin-password   # only if --admin-user was set; mode 0600
└── (optional) compose.override.yaml   # your customisations
```

Container data lives in Docker-managed volumes:

```text
webtrees_database   ~50 MB+   MariaDB data files
webtrees_media      depends   uploaded photos / documents
webtrees_app        ~200 MB   webtrees source + vendor (re-seeded on image upgrade)
webtrees_secrets    ~1 KB     auto-generated DB + admin passwords
```

Inspect with `docker volume ls | grep webtrees`.

## Customising

Full guide: [`docs/customizing.md`](docs/customizing.md) — covers
`compose.override.yaml` patterns (PHP limits, custom nginx snippets,
external database, third-party modules) plus Backup / Restore.

## Updating to a new webtrees release

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/upgrade | bash
```

The `upgrade` launcher stops the stack, drops `webtrees_app` so the
new image can re-seed it, and re-runs the installer with `--force`.
`webtrees_database` and `webtrees_media` survive the upgrade. Pass
custom flags via `bash -s -- --port 8443` if you deviate from the
quickstart defaults.

If you prefer to step through manually (audit each command before
it runs, or tweak individual steps):

```bash
docker compose down
docker volume rm webtrees_app
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --non-interactive --no-admin --edition full --proxy standalone --port 8080 --force
docker compose pull
docker compose up -d
```

## Backup

Full procedure (DB dump, media tar, restore, scheduling): see
[`docs/customizing.md`](docs/customizing.md#backup).

## Troubleshooting

- **Port already in use** — the wizard probes the requested port and
  falls back to 8080 automatically. If 8080 is also taken, pass
  `--port <free-port>` explicitly.
- **`docker compose pull` fails** — confirm GHCR is reachable
  (`docker pull ghcr.io/magicsunday/webtrees/nginx:1.28-r1`) and re-run.
- **Admin login fails** — the password lives in `.webtrees-admin-password`
  and was printed once when the wizard finished. `cat` the file to read it.
- **`docker: command not found`** — you haven't installed Docker yet.
  See *Before you start* above and follow the official Docker Engine
  install guide for your platform.
- **`permission denied while trying to connect to the Docker daemon
  socket`** — your user isn't in the `docker` group. Run
  `sudo usermod -aG docker $USER`, then log out and back in (group
  membership is read at login).
- **Wizard hangs on a prompt** — you piped `curl` into `bash` without
  `--non-interactive`. Interactive prompts can't read from a pipe; add
  the flag or download the script first and run it directly.
- **How do I update?** — see the *Updating to a new webtrees release*
  section above. The `upgrade` one-liner handles the common case.
- **How do I back up?** — see [`docs/customizing.md`](docs/customizing.md#backup)
  for DB dump, media tar, restore, and scheduling.
- **How do I add custom modules?** — see [`docs/customizing.md`](docs/customizing.md)
  for the `compose.override.yaml` pattern that bind-mounts a modules
  directory into phpfpm.
- **I'm behind a corporate proxy** — export `HTTP_PROXY` /
  `HTTPS_PROXY` / `NO_PROXY` in the shell before running the
  one-liner, and configure the Docker daemon itself to use the proxy
  (see Docker's networking docs). Otherwise image pulls will fail.
- **My server can't reach GHCR** — check egress firewall rules for
  `ghcr.io` and `*.githubusercontent.com`. If GHCR requires
  authentication in your environment, run `docker login ghcr.io`
  before the wizard.
- **webtrees lost my data after upgrade** — you removed too many
  volumes. Only `webtrees_app` is safe to drop on upgrade;
  `webtrees_database` and `webtrees_media` hold your trees and uploads
  and must be preserved. Restore from your latest backup.

## For module developers

Comprehensive guide: [`docs/developing.md`](docs/developing.md).

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
