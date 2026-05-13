# webtrees-docker — Developer Guide

This guide is for maintainers of `webtrees-docker` itself: the wizard, the
Docker images, and the compose chain. Self-hosters should follow the
[README](../README.md) instead.

## Repo Layout

| Path | Purpose |
|---|---|
| `installer/` | Python wizard (Jinja templates + pytest suite) |
| `rootfs/` | Files baked into the images at build time (nginx config, entrypoint scripts) |
| `app/` | Bind-mounted webtrees source for `--mode dev` |
| `setup/` | Composer manifests for the `core` and `full` editions plus webtrees patches |
| `scripts/` | Buildbox helper scripts invoked by the make targets |
| `Dockerfile` | Multi-stage build (webtrees-build, webtrees-build-full, php-base, php-build, php-build-full, build-box, nginx-build); the wizard image is built separately from `installer/Dockerfile` |
| `compose.yaml` | Base service definitions (db, phpfpm, nginx) |
| `compose.*.yaml` | Overlays merged into the chain via `COMPOSE_FILE` (publish, traefik, development, pma, modules, external) |
| `Make/*.mk` | Make targets grouped by topic (application, build, docker, test, helpers) |
| `dev/versions.json` | Manifest of supported webtrees + PHP version pairs driving CI |
| `.github/workflows/` | `build.yml` (image build + smoke matrix) and `check-versions.yml` |
| `tests/` | Host-side entrypoint tests (`tests/test-entrypoint.sh`) |

## Setup

Clone the repo and run the wizard in dev mode through the bundled
launcher — it injects `--local-user-id $(id -u)` / `--local-user-name
$(id -un)` so the rendered `.env` carries the host UID (the wizard runs
as root inside its container and cannot detect it otherwise):

```bash
git clone https://github.com/magicsunday/webtrees-docker.git
cd webtrees-docker
./install --mode dev
```

The wizard writes `.env` with the dev compose chain — `compose.yaml +
compose.pma.yaml + compose.development.yaml`, plus
`compose.publish.yaml` in standalone proxy mode — and bind-mounts
`./app` into phpfpm. Bring the stack up with `make up`; webtrees lives
at `http://localhost:50010`, phpMyAdmin at `http://localhost:50011`.

Use `./switch standalone` to flip back to the self-host stack for
browser testing without losing your dev DB creds.

## Wizard Development

The Python wizard lives in `installer/` and has its own pytest suite
(113 tests covering rendering, prompts, prerequisites, port probing,
secrets, demo-tree generation, dev flow).

```bash
cd installer
pip install -e .[test]
pytest -q
```

Build the wizard image locally:

```bash
docker build -f installer/Dockerfile -t webtrees-installer:dev .
```

Render-only smoke against a throwaway workdir:

```bash
mkdir -p /tmp/wizard-smoke
docker run --rm \
  -v /tmp/wizard-smoke:/work \
  webtrees-installer:dev \
  --non-interactive --no-up --no-admin \
  --edition full --proxy standalone --port 8080
ls /tmp/wizard-smoke
```

## Image Builds

CI publishes four image families to `ghcr.io/magicsunday/webtrees/`:
`php`, `php-full`, `nginx`, and `installer`. The build is triggered
either manually or by a tag push:

```bash
gh workflow run build.yml --ref main
# or
git tag v1.2.3 && git push origin v1.2.3
```

`dev/versions.json` is the manifest. The matrix expands to every entry
× `{php, php-full}` plus a single `nginx` and `installer` build. A
follow-up smoke job spins each `{core, full, demo}` edition up against
the freshly built images.

## Common Make Targets

Stack lifecycle:

| Target | Action |
|---|---|
| `make up` | Bring the compose chain up (`docker compose up -d`). |
| `make down` | Stop and remove containers + the local dev volumes. |
| `make restart` | Restart all services. |
| `make status` | `docker compose ps`. |
| `make logs` | Tail container logs. |
| `make config` | Print the merged compose configuration. |

Buildbox + application:

| Target | Action |
|---|---|
| `make bash` | Shell into the buildbox as the configured user. |
| `make bash-root` | Same, but as root. |
| `make build` | Rebuild the local images (dev mode only). |
| `make install` | Run the application install scripts inside the buildbox. |
| `make composer-install` | Composer install with the locked versions. |
| `make composer-update` | Composer update against `app/composer.json`. |
| `make update-languages` | Resync the webtrees language files. |
| `make apply-config` | Re-apply the webtrees configuration to an existing install. |
| `make cache-clear` | Clear the webtrees cache directory. |
| `make test` | Run the entrypoint state-machine tests on the host. |
| `make ci-test` | Run the full local CI aggregate — green here is the precondition for every commit. |

Run `make help` for the full list.

### `make ci-test` — green-before-commit

`make ci-test` bundles every static-analysis + unit-test step that CI also
runs, so a green local run reliably predicts a green GitHub Actions run.

Today's bundle:

- `make ci-pytest` — installer Python test suite (137+ cases).
- `make ci-yamllint` — workflow + compose YAML lint (line-length is a
  warning, not an error: GHA `run:` blocks routinely carry long inline
  strings).
- `make ci-hadolint` — Dockerfile lint at the `error` failure threshold;
  warnings stay visible but do not fail the build.
- `make ci-entrypoint` — entrypoint state-machine integration tests
  against the canonical published php image (tag resolved from
  `dev/versions.json`).

Every check has its own sub-target for fast iteration. Add new checks to
this aggregate (not as a separate workflow) — the single-source-of-truth
property is what makes the local-CI parity useful.

## Module Developer Workflow

To hack on a webtrees module against this stack, clone the module
alongside `webtrees-docker` and either install it via composer from a
local path repository or drop it into `./modules/` and add
`compose.modules.yaml` to the `COMPOSE_FILE` chain in `.env`. Edits on
the host are picked up live thanks to the `./app` bind-mount; restart
phpfpm after composer changes:

```bash
docker compose restart phpfpm nginx
```

Modules that ship shared PHP via `magicsunday/webtrees-module-base` use
their own `make link-base` target (defined in the module repo) to swap
the vendored copy for a sibling working tree. That workflow is
documented in the respective module repository.

## Where to Make Changes

Specifications live under `docs/superpowers/specs/`, executable plans
under `docs/superpowers/plans/`. Update both when the contract or the
work order shifts. Memory files under `~/.claude/projects/.../memory/`
hold long-lived conventions and gotchas; promote anything broadly
applicable there once it has stuck.

## License

MIT — see [LICENSE](../LICENSE).
