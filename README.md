# Webtrees Self-Host

[![Build](https://img.shields.io/github/actions/workflow/status/magicsunday/webtrees-docker/build.yml?branch=main&label=build)](https://github.com/magicsunday/webtrees-docker/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/magicsunday/webtrees-docker?label=release)](https://github.com/magicsunday/webtrees-docker/releases/latest)
[![License](https://img.shields.io/github/license/magicsunday/webtrees-docker)](LICENSE)
[![webtrees](https://img.shields.io/badge/webtrees-2.1.27%7C2.2.6-blue)](https://www.webtrees.net/)
[![PHP](https://img.shields.io/badge/PHP-8.3%7C8.4%7C8.5-787CB5)](dev/versions.json)

Docker images and a wizard for running [webtrees](https://www.webtrees.net/)
without writing your own compose file.

> New to Docker terms? Skip ahead to the [Glossary](#glossary) — it
> explains "stack", "volume", "GHCR", "reverse proxy" etc. in one
> line each.

## Before you start

**Brand new to Docker?** On a personal computer (Mac or Windows), the
easiest path is [Docker Desktop](https://www.docker.com/products/docker-desktop/) —
download, install, launch it once, then come back here. On a Synology,
QNAP, or Ugreen NAS, install the "Docker" / "Container Manager" package
from the built-in app store.

Otherwise you need a host with Docker Engine installed:

- **Linux**: follow <https://docs.docker.com/engine/install/> for your distro
  (Ubuntu/Debian/Fedora/Arch all supported). To run `docker` without typing
  `sudo` each time, run `sudo usermod -aG docker $USER` and then log out
  and back in.
- **Synology / QNAP / generic NAS appliances**: install the Docker / Container Manager
  package from your NAS app store. The wizard binds the docker socket
  at `/var/run/docker.sock` — make sure that's reachable.
- **Docker Desktop (Mac / Windows)**: works for trying it out, but for
  production self-hosting we recommend Linux on a small VPS or NAS.

To check it's working, open a terminal and run `docker version` and
`docker compose version` (two words, with a space). Both should print
version numbers without errors. If `docker compose version` says
`is not a docker command`, your Docker install is missing the Compose
plugin — follow [Docker's Compose install guide](https://docs.docker.com/compose/install/)
to add it.

That's all. The wizard takes care of the rest — no PHP, MariaDB, or
nginx to install yourself.

## Quickstart

The command below downloads the installer and runs it with sensible
defaults. After it finishes, you can log straight into webtrees with
an auto-created admin user — replace the email with your own.

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --non-interactive --edition full --proxy standalone --port 28080 \
      --admin-user admin --admin-email me@example.org
```

> Prefer to inspect the script first? Open
> <https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install>
> in your browser, read it, then download and run it locally instead
> of piping into bash.
>
> Want webtrees' own setup screen instead of an auto-created admin?
> Replace `--admin-user … --admin-email …` with `--no-admin`.

The wizard writes `compose.yaml` + `.env` into the current directory and
brings the stack up via `docker compose up -d`.

**You'll know it worked when** the terminal prints a banner with a URL
(plus your admin password, **which is shown only once — copy it now**).
Open the URL in your browser; you should see the webtrees logo and a
login form.

The URL the banner prints is the one to use. `localhost` only works if
you ran the wizard on the same computer you're browsing from. If you
installed on a NAS or a remote server, point your browser at that
machine's address — e.g. `http://192.168.1.50:28080/`. You can find
the address in your router's admin page or your NAS dashboard.

First-run takes about 2 minutes on a typical home connection — most
of that is a one-time download of the wizard + webtrees images
(roughly 300 MB total). Subsequent runs reuse the cached images and
are much faster.

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
| Full (default) | `webtrees-php-full` | + the chart modules pinned in [`setup/composer-full-2.2.json`](setup/composer-full-2.2.json) / [`setup/composer-full-2.1.json`](setup/composer-full-2.1.json) (currently fan, pedigree, descendants — interactive family-tree visualisations) |
| Full + Demo | same as Full | + a 7-generation synthetic family tree imported on first boot |

`--edition core` / `full` selects between the first two; add `--demo`
to also seed the demo tree (useful if you want to explore webtrees
before importing your own family data — the example family loads on
first start).

## Proxy modes

**Not sure?** Pick `--proxy standalone` (the default). It works for
"open webtrees on port 28080 on my server" with no extra setup. Only
switch to `--proxy traefik` if you already run Traefik and know what
that means.

| Proxy | Flag | When to use |
|---|---|---|
| Standalone | `--proxy standalone --port <port-number, e.g. 28080>` | nginx publishes the chosen port directly. Use this whether you have no reverse proxy at all, or whether you already run one (Caddy, nginx-proxy, Cloudflare Tunnel, …) that you'll point at the published port yourself. |
| Traefik | `--proxy traefik --domain <your-domain, e.g. webtrees.example.org>` | nginx joins the `traefik` external network and answers under your Traefik router. Requires a running Traefik instance already attached to that network — see [`docs/proxy-traefik.md`](docs/proxy-traefik.md). |

`--proxy` selects how the stack publishes itself. It is independent
of `--mode` (which switches between operator and module-developer
install flows — only relevant if you're hacking on webtrees itself,
see [For module developers](#for-module-developers)). The two flags
happen to share `standalone` as a default but are orthogonal axes.

## Glossary

- **Host** — the computer running Docker — your laptop, NAS, or
  server.
- **Docker socket** — the file Docker uses to receive commands; the
  wizard needs to read it (the install path takes care of that for
  you).
- **Reverse proxy** — an extra program (Caddy, nginx-proxy, Traefik,
  Cloudflare Tunnel, …) that sits in front of webtrees to add HTTPS
  or route multiple domains. You probably don't need one to start.
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
- **GHCR** — GitHub Container Registry — where the prebuilt webtrees
  images live. All images are pulled from
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
  `--port <a-different-port-number, e.g. 28090>` explicitly.
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
- **Server can't reach GHCR** — check whether your network blocks
  outgoing connections to `ghcr.io` and `*.githubusercontent.com`.
  Quick verify:
  `docker pull ghcr.io/magicsunday/webtrees-installer:latest`. If GHCR
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
