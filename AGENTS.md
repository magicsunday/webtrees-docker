<!-- GENERATED:agent-rules -->
# AGENTS.md

This file orients AI coding agents working on `webtrees-docker`. Humans should
read [`README.md`](README.md) (self-hosters) or [`docs/developing.md`](docs/developing.md)
(maintainers) instead.

## Project

| | |
|---|---|
| Purpose | Docker images + Python wizard for self-hosting [webtrees](https://www.webtrees.net/) |
| Stacks | Python 3.12 wizard (`installer/`), multi-stage `Dockerfile` (PHP-FPM + nginx), bash launchers (`install`, `upgrade`) |
| Distribution | Container images on `ghcr.io/magicsunday/webtrees/{php,php-full,nginx,installer}`; matrix lives in `dev/versions.json` |
| Entry point for end-users | `curl … /install \| bash` |

## Repo layout

| Path | Purpose |
|---|---|
| `installer/webtrees_installer/` | Python wizard package: CLI, flow orchestrators, render, prompts |
| `installer/templates/*.j2` | Jinja2 sources for the rendered `compose.yaml` / `.env` |
| `installer/tests/` | pytest suite |
| `installer/Dockerfile` | Wizard image — separate build, shipped as `installer:<tag>` |
| `Dockerfile` | Multi-stage build for `php` / `php-full` / `nginx` (stages: `webtrees-build`, `webtrees-build-full`, `php-base`, `php-build`, `php-build-full`, `build-box`, `nginx-build`) |
| `rootfs/` | Files baked into the runtime images at build time |
| `compose.yaml` + `compose.*.yaml` | Base + override chain; the wizard picks subsets per mode |
| `setup/` | Composer manifests (`composer-core.json` / `composer-full.json`) + patch files |
| `dev/versions.json` | PHP × webtrees matrix the build workflow expands |
| `.github/workflows/build.yml` | Image build + smoke matrix (manual / tag-triggered) |
| `.github/workflows/check-versions.yml` | Daily cron polling upstream webtrees releases |
| `docs/superpowers/specs/` | Authoritative architecture spec |
| `docs/superpowers/plans/` | Executable plan docs (Phase 1, 2a, 2b, 3) |
| `docs/developing.md` | Module-maintainer guide |
| `docs/customizing.md` | Self-hoster customising + backup |

## Build & test

| Command | Effect |
|---|---|
| `docker run --rm -v $(pwd)/installer:/work -w /work python:3.14-alpine sh -c "pip install -q -e .[test] && pytest -q"` | Run wizard tests (no host Python on the dev NAS) |
| `docker build -f installer/Dockerfile -t webtrees-installer:dev .` | Build wizard image locally |
| `gh workflow run build.yml -R magicsunday/webtrees-docker --ref main` | Trigger full image-matrix + smoke build on CI |
| `gh workflow run check-versions.yml -R magicsunday/webtrees-docker --ref main` | Run the upstream-release poller |
| `docker run --rm -v /volume2/docker/webtrees:/repo -w /repo rhysd/actionlint:latest <workflow>` | Lint a workflow file |

No host PHP / Node / buildx is available on the dev NAS — see
[`reference_environment`](/home/rso/.claude/memory/reference_environment.md)
in global memory. Multi-platform image builds run only on CI.

## Working with the wizard

| Task | Path |
|---|---|
| Add a CLI flag | `installer/webtrees_installer/cli.py` + a test in `installer/tests/test_cli.py` |
| Change rendered compose / env | edit the Jinja template in `installer/webtrees_installer/templates/` + extend `installer/tests/test_render.py` |
| Touch the dev flow | `installer/webtrees_installer/dev_flow.py` + `installer/tests/test_dev_flow.py` |
| Touch the standalone flow | `installer/webtrees_installer/flow.py` + `installer/tests/test_flow.py` |
| Update version matrix | `dev/versions.json` |

## Workflow conventions

| Rule | Source of truth |
|---|---|
| Capitalised verb commit subject; no `chore:` / `feat:` prefix | global memory `feedback_git_commits` |
| Never add `Co-Authored-By` trailers | global memory `feedback_git_commits` |
| Never amend commits; always create new ones | project memory `feedback_commit_discipline` |
| `git -C /volume2/docker/webtrees …` — bash cwd does not persist across Bash tool invocations | project memory `feedback_pwd_before_git` |
| Reviews iterate until clean; after every "Approved" run a second independent review | global memory `feedback_double_review_loop` |
| No `Co-Authored-By`, no GH issue numbers / commit SHAs / external repo references in commit bodies | project memory `feedback_neutral_commit_messages` |
| All code comments in English; planning docs may be German | project memory `feedback_code_comments_english` |
| Don't push without explicit user "go" for any tagged release | project memory `feedback_release_needs_explicit_go` |

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
  `<<<` here-string instead of `printf … |`.

## Out of scope for this file

Self-host install instructions → [`README.md`](README.md).
Module-developer onboarding → [`docs/developing.md`](docs/developing.md).
Customising / backup → [`docs/customizing.md`](docs/customizing.md).
Architecture rationale → `docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md`.
<!-- /GENERATED:agent-rules -->
