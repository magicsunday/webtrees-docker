# Webtrees Self-Host

[![Build](https://img.shields.io/github/actions/workflow/status/magicsunday/webtrees-docker/build.yml?branch=main&label=build)](https://github.com/magicsunday/webtrees-docker/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/magicsunday/webtrees-docker?label=release)](https://github.com/magicsunday/webtrees-docker/releases/latest)
[![License](https://img.shields.io/github/license/magicsunday/webtrees-docker)](LICENSE)
[![webtrees](https://img.shields.io/badge/webtrees-2.1.27%7C2.2.6-blue)](https://www.webtrees.net/)
[![PHP](https://img.shields.io/badge/PHP-8.3%7C8.4%7C8.5-787CB5)](dev/versions.json)

Docker images and a wizard for running [webtrees](https://www.webtrees.net/)
without writing your own compose file.

## Before you start

You need a host with Docker Engine installed:

- **Linux**: follow <https://docs.docker.com/engine/install/> for your distro
  (Ubuntu/Debian/Fedora/Arch all supported). Add your user to the `docker`
  group so you can run `docker` without `sudo`.
- **Synology / QNAP / generic NAS appliances**: install the Docker / Container Manager
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
  | bash -s -- --non-interactive --no-admin --edition full --proxy standalone --port 28080
```

(Or with admin auto-create: drop `--no-admin` and add `--admin-user admin --admin-email me@example.org`.)

The wizard writes `compose.yaml` + `.env` into the current directory and
brings the stack up via `docker compose up -d`. Visit `http://localhost:28080/`.

When you run the one-liner, the wizard:

1. Pulls the wizard image (~55 MB compressed, ~165 MB on-disk, one-time).
2. Renders `compose.yaml` and `.env` into your current directory.
3. Pulls the application images (~260 MB download, ~765 MB on-disk, one-time).
4. Starts the stack via `docker compose up -d`.
5. Prints the URL plus admin credentials (if you chose `--admin-user`).

Total first-run time: ~2 minutes on a 100 Mbit link, less on subsequent runs.

After the wizard finishes, your stack is reachable at the URL it printed.
The first time you visit, webtrees runs its own setup wizard (or auto-
provisions if you passed `--admin-user`).

### Portainer? One-click via stack URL

If you run Portainer, paste this URL into *Stacks → Add stack →
Web URL* instead of running the curl one-liner:

```text
https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/templates/portainer/compose.yaml
```

The companion [`.env.example`](templates/portainer/.env.example) goes
in the *Environment variables → Advanced mode* pane. Full walkthrough
in [`docs/portainer.md`](docs/portainer.md).

## Editions

| Edition | Image | Contains |
|---|---|---|
| Core | `webtrees-php` | Plain webtrees release |
| Full (default) | `webtrees-php-full` | + Magic-Sunday charts: [fan](https://github.com/magicsunday/webtrees-fan-chart), [pedigree](https://github.com/magicsunday/webtrees-pedigree-chart), [descendants](https://github.com/magicsunday/webtrees-descendants-chart) |
| Full + Demo | same as Full | + a 7-generation synthetic family tree imported on first boot |

`--edition core` / `full` selects between the first two; add `--demo`
to also seed the demo tree.

## Modes

| Mode | Flag | When to use |
|---|---|---|
| Standalone | `--proxy standalone --port <N>` | Single host, no reverse proxy. nginx publishes the chosen port. |
| Traefik | `--proxy traefik --domain <fqdn>` | nginx joins the `traefik` external network and answers under your Traefik router. Requires a running Traefik instance already attached to that network — see [`docs/proxy-traefik.md`](docs/proxy-traefik.md). |

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
  restarts. Each volume is prefixed with your stack's project name (the
  directory basename — `webtrees` for the canonical install path), so
  your stack has `<project>_database`, `<project>_media`,
  `<project>_app`, `<project>_secrets`.
- **GHCR** — GitHub Container Registry. All images are pulled from
  `ghcr.io/magicsunday/webtrees-{php,php-full,nginx,installer}`.

## What the wizard writes

- `compose.yaml` — services, named volumes, healthchecks.
- `.env` — image tags + (standalone) the host port override.
- `Makefile` — one-word shortcuts for everyday stack operations.

The autogenerated admin password is printed in the install banner and
nowhere else — no file on disk. Copy it before closing the terminal.

Subsequent `docker compose pull && docker compose up -d` re-uses the same files.

### Everyday `make` targets

The Makefile in your install dir wraps the most common docker compose
invocations behind one-word targets: `up`, `down`, `restart`, `logs`,
`pull`, `shell`, `cli`, `backup`, `restore`. Run `make` (or `make help`)
in the install dir for the full list with usage examples — the help
text lives next to the recipes so it stays in lock-step with whatever
the local Makefile actually does.

## What gets installed where

Your current directory after the wizard runs:

```text
.
├── compose.yaml          # generated; do not edit directly
├── .env                  # generated; image tags + ports live here
└── (optional) compose.override.yaml   # your customisations
```

Container data lives in Docker-managed volumes (each prefixed with your
stack's project name — the directory basename, `webtrees` for the
canonical install path):

```text
<project>_database   ~50 MB+   MariaDB data files
<project>_media      depends   uploaded photos / documents
<project>_app        ~80 MB+   webtrees source + vendor (re-seeded on upgrade)
<project>_secrets    ~1 KB     auto-generated DB + admin passwords
```

Inspect with `docker volume ls`.

## Customising

Full guide: [`docs/customizing.md`](docs/customizing.md) — covers
`compose.override.yaml` patterns (PHP limits, custom nginx snippets,
external database, third-party modules) plus Backup / Restore.

## Upgrades, mode switches, line choice

- **Updating to a new webtrees release** (one-liner + manual fallback)
  → [`docs/upgrade.md`](docs/upgrade.md#updating-to-a-new-webtrees-release)
- **Switching between standalone and dev mode**
  → [`docs/upgrade.md`](docs/upgrade.md#switching-modes)
- **Choosing which webtrees line your install tracks** (2.1 LTS vs
  2.2 current) → [`docs/upgrade.md`](docs/upgrade.md#choosing-a-webtrees-line)

## Backup

Full procedure (DB dump, media tar, restore, scheduling): see
[`docs/customizing.md`](docs/customizing.md#backup).

## Troubleshooting

The five things most people hit:

- **Port already in use** — the wizard probes the requested port and
  falls back to 28081 automatically. If 28081 is also taken, pass
  `--port <free-port>` explicitly.
- **Admin login fails** — the password is printed once in the install
  banner and not saved to disk. If you missed it, re-run the wizard
  with `--force` to regenerate (your tree data in the named volumes
  survives).
- **`docker: command not found` / permission denied on the docker
  socket** — see *Before you start* above and follow the Docker
  Engine install guide for your platform. After installing, add your
  user to the `docker` group (`sudo usermod -aG docker $USER`) and
  log out + back in.
- **Wizard hangs on a prompt** — you piped `curl` into `bash` without
  `--non-interactive`. Interactive prompts can't read from a pipe;
  add the flag or download the script first.
- **webtrees lost my data after upgrade** — you removed too many
  volumes. Only `<project>_app` is safe to drop on upgrade;
  `<project>_database` and `<project>_media` hold your trees and
  uploads. Restore from your latest backup.

Everything else lives in the topic docs:

- Installer flags / scenarios → [`docs/installer-reference.md`](docs/installer-reference.md)
- Traefik setup + TLS / router troubleshooting → [`docs/proxy-traefik.md`](docs/proxy-traefik.md)
- HTTPS + cert chain diagnosis → [`docs/https-certs.md`](docs/https-certs.md)
- Backup / restore / custom modules → [`docs/customizing.md`](docs/customizing.md)

Network-connectivity edge cases:

- **Behind a corporate proxy** — export `HTTP_PROXY` / `HTTPS_PROXY`
  / `NO_PROXY` in the shell before running the one-liner, AND
  configure the Docker daemon itself to use the proxy (see Docker's
  networking docs). Otherwise image pulls fail.
- **Server can't reach GHCR** — check egress firewall rules for
  `ghcr.io` and `*.githubusercontent.com`. Quick verify:
  `docker pull ghcr.io/magicsunday/webtrees-nginx:1.30-r1`. If GHCR
  requires authentication in your environment, run
  `docker login ghcr.io` before the wizard.

## Power-user paths

- Operator with an existing curated compose stack who wants to add
  webtrees without the wizard → [`docs/diy.md`](docs/diy.md). Lists
  the env-var contract per service, mount points, healthchecks, and
  a minimal hand-written `compose.yaml`.
- Wizard-driven BYOD (external DB, host-path data, reused volumes)
  → [`docs/byod.md`](docs/byod.md).

## Contributing

Project standards — design-principle order, code conventions,
audit-loop discipline — are codified in
[`CONTRIBUTING.md`](CONTRIBUTING.md). Read it before opening a PR.
AI coding agents start at [`AGENTS.md`](AGENTS.md).

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
  ghcr.io/magicsunday/webtrees-installer:latest --mode dev
```

The dev flow writes a `.env` with the compose chain that bind-mounts
`./app` into phpfpm and brings in buildbox + xdebug + phpMyAdmin.

## License

MIT — see [LICENSE](LICENSE).
