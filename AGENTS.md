<!-- GENERATED:agent-rules -->
# AGENTS.md

This file orients AI coding agents working on `webtrees-docker`. Humans should
read [`README.md`](README.md) (self-hosters) or [`docs/developing.md`](docs/developing.md)
(maintainers) instead.

## Project

| | |
|---|---|
| Purpose | Docker images + Python wizard for self-hosting [webtrees](https://www.webtrees.net/) |
| Stacks | Python wizard (`installer/`, ≥3.12), multi-stage `Dockerfile` (PHP-FPM + nginx), bash launchers (`install`, `upgrade`) |
| Distribution | Container images on `ghcr.io/magicsunday/webtrees/{php,php-full,nginx,installer}`; matrix lives in `dev/versions.json` |
| Entry point for end-users | `curl … /install \| bash` |

## Repo layout

| Path | Purpose |
|---|---|
| `installer/webtrees_installer/` | Python wizard package: CLI, flow orchestrators, render, prompts |
| `installer/webtrees_installer/templates/*.j2` | Jinja2 sources for the rendered `compose.yaml` / `.env` |
| `installer/tests/` | pytest suite |
| `installer/Dockerfile` | Wizard image — separate build, shipped as `installer:<tag>` |
| `Dockerfile` | Multi-stage build for `php` / `php-full` / `nginx` (stages: `webtrees-build`, `webtrees-build-full`, `php-base`, `php-build`, `php-build-full`, `build-box`, `nginx-build`) |
| `rootfs/` | Files baked into the runtime images at build time |
| `compose.yaml` + `compose.*.yaml` | Base + override chain; the wizard picks subsets per mode |
| `setup/` | Composer manifests (`composer-core.json` / `composer-full.json`) + patch files |
| `dev/versions.json` | PHP × webtrees matrix the build workflow expands |
| `.github/workflows/build.yml` | Image build + smoke matrix (manual / tag-triggered) |
| `.github/workflows/check-versions.yml` | Daily cron polling upstream webtrees releases |
| `docs/developing.md` | Module-maintainer guide |
| `docs/customizing.md` | Self-hoster customising + backup |
| `docs/env-vars.md` | Env-var inventory + collision audit (every name → consumer + default) |
| `docs/portainer.md` | Portainer one-click stack walkthrough |
| `templates/portainer/` | Release-time pre-rendered `compose.yaml` + `.env.example` for Portainer's Web-URL import path |
| `scripts/render-portainer-templates.sh` | Maintainer helper that re-renders `templates/portainer/` from the installer's Jinja sources; invoke via `make portainer-templates` at release time |

## Build & test

| Command | Effect |
|---|---|
| `docker run --rm -v $(pwd)/installer:/work -w /work python:3.14-alpine sh -c "pip install -q -e .[test] && pytest -q"` | Run wizard tests in a throwaway Python container |
| `docker build -f installer/Dockerfile -t webtrees-installer:dev .` | Build wizard image locally |
| `gh workflow run build.yml --ref main` | Trigger full image-matrix + smoke build on CI |
| `gh workflow run check-versions.yml --ref main` | Run the upstream-release poller |
| `docker run --rm -v $(pwd):/repo -w /repo rhysd/actionlint:latest <workflow>` | Lint a workflow file |

Multi-platform image builds (linux/amd64 + linux/arm64) are slow under
qemu emulation; rely on CI for the full matrix.

## Working with the wizard

| Task | Path |
|---|---|
| Add a CLI flag | `installer/webtrees_installer/cli.py` + a test in `installer/tests/test_cli.py` |
| Change rendered compose / env | edit the Jinja template in `installer/webtrees_installer/templates/` + extend `installer/tests/test_render.py` |
| Touch the dev flow | `installer/webtrees_installer/dev_flow.py` + `installer/tests/test_dev_flow.py` |
| Touch the standalone flow | `installer/webtrees_installer/flow.py` + `installer/tests/test_flow.py` |
| Update version matrix | `dev/versions.json` |

## Recent traps to avoid

- **Compose v2 `$var` interpolation in YAML command strings** — escape as
  `$$var` so the in-container shell sees a literal. See
  `installer/webtrees_installer/templates/compose.standalone.j2` init
  service.
- **composer:2 image PHP version drifts** — pin via
  `composer config platform.php "${PHP_VERSION}.0"` before
  `composer install` in `Dockerfile`. Otherwise the
  `vendor/composer/platform_check.php` refuses to load on the runtime PHP.
- **buildkit ≥0.18 mounts `/etc/hosts` read-only inside `RUN`** — use the
  `add-hosts:` input on `docker/build-push-action` instead of
  `echo … >> /etc/hosts`.
- **`grep -q` SIGPIPE inside a pipefail pipeline** — feed the body via a
  `<<<` here-string instead of `printf … |`, or eliminate the pipeline
  entirely by capturing the upstream output into a variable
  (`out=$(cmd) || exit 1`) and operating on `"$out"` from there. The
  captured-variable form also surfaces the upstream command's exit
  status, which the pipefail-vs-`if` shape silently swallows.

## Out of scope for this file

Self-host install instructions → [`README.md`](README.md).
Module-developer onboarding → [`docs/developing.md`](docs/developing.md).
Customising / backup → [`docs/customizing.md`](docs/customizing.md).
Architecture rationale lives with the maintainer's notes outside the repo;
ask the maintainer if you need it.
<!-- /GENERATED:agent-rules -->
