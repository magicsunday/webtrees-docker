# Maintenance procedures

Operator-facing procedures for routine maintenance work on the
webtrees-docker stack. Each section is keyed by the polling workflow
that surfaces the underlying tracking issue.

For day-to-day development workflows see `AGENTS.md`; for the
installer's user-facing wizard see `docs/installer-reference.md`.

## Polling workflow overview

Four cron-driven workflows under `.github/workflows/check-*.yml` poll
their respective registries once a day and open a tracking issue when
upstream publishes a tag newer than the current pin:

  * `check-mariadb.yml` — Docker Hub library/mariadb, daily 12:15 UTC.
  * `check-php.yml` — Docker Hub library/php (digest + minor scan), daily 12:30 UTC.
  * `check-alpine.yml` — Docker Hub library/alpine, daily 12:45 UTC.
  * `check-nginx.yml` — Docker Hub library/nginx, daily 13:00 UTC.

The workflows never mutate the repo. Each issue body links here, and
each section below carries the corresponding `./scripts/bump-*.sh`
invocation (and equivalent `make bump-*` form) plus the post-bump
review and verification steps.

A fifth workflow, `.github/workflows/check-versions.yml`, polls
fisharebest/webtrees for new application releases. Unlike the four
check-\* workflows above, it opens an auto-merge PR per new version
directly (appending a row to `dev/versions.json` and regenerating the
README badges) rather than a tracking issue — see the workflow file
itself for the exact loop semantics.

## Trust model and recommended invocation

Two entry points exist for every bump:

  * **`./scripts/bump-nginx.sh <new-minor>`** /
    **`./scripts/bump-mariadb.sh <new-minor>`** — the recommended
    form. Argv lands on the Python implementation directly, never
    passing through Make's command-line parser. Robust against
    `$(shell …)` / `:=` / `::=` / `!=` / `CURDIR=` injection.
  * **`make bump-nginx VERSION=… [CONFIG_REVISION=…]`** /
    **`make bump-mariadb VERSION=…`** — a convenience wrapper for
    trusted-local invocations. Validates pure-shell metacharacters
    (backtick, semicolon, pipe, ampersand, redirect, quote, escape)
    at Make parse time and delegates to the script form. GNU Make
    4.4+ evaluates command-line `$(shell …)` / `:=` / `::=` / `!=`
    / `CURDIR=` assignments at parse time, before any directive in
    any Makefile can run — that class of injection is structurally
    impossible to block from inside any Makefile, so operators
    pasting a `make bump-…` invocation from chat, README, gist, or
    any untrusted source must use the script form instead.

The script form is also what `make bump-*` invokes internally, so
behaviour is identical when the inputs are well-formed; the
difference is solely in the threat surface of the entry point.

## Bumping the nginx pin

Triggered by a `nginx X.Y-alpine available` issue from `check-nginx.yml`.

### Stable-only policy

nginx publishes two parallel branches:

  * **Stable** — even-numbered minors (1.26, 1.28, 1.30, …). Production-
    suited. Only critical fixes land on the active stable line.
  * **Mainline** — odd-numbered minors (1.27, 1.29, 1.31, …). Carries
    new features and experimental changes; not production-suited.

This project pins the stable line. `check-nginx.yml` filters Docker Hub
results to even-numbered minors (`awk -F. '$2 % 2 == 0'`) so mainline
releases do not trigger spurious bump tickets. The filter is enforced
by the workflow's self-test: a pinned mainline minor would fail because
it could not survive the even-only filter.

### 1. Review release notes

  * Stable-branch changelog: `https://nginx.org/en/CHANGES-X.Y`
    (substitute the new minor, e.g. `https://nginx.org/en/CHANGES-1.32`).
    `nginx.org/en/CHANGES` carries the mainline changelog only and is
    not the right page for this project's pin track.
  * Focus on directive renames, removed/added modules, default-value
    changes, and any item flagged "Backward incompatibility".
  * Particularly relevant for this stack: `http_realip_module`,
    `gzip_static`, `proxy_*` directives, `set_real_ip_from` (used by
    `tests/test-trust-proxy-extra.sh`), and `start_period` semantics
    in the healthcheck.

### 2. Run the bumper

```bash
./scripts/bump-nginx.sh <new-minor>
```

(`make bump-nginx VERSION=<new-minor>` is equivalent but exposes the
Make-injection surface described in the trust model above.)

The script invokes `scripts/bump-nginx.py` inside a python:3.13-slim
container, which:

  * Updates `dev/nginx-version.json` — `nginx_base`, `config_revision`
    (reset to `1` on a minor bump), `.tag` = `<base>-r<revision>`.
  * sed-replaces the five mirror sites enforced by
    `installer/tests/test_nginx_tag_lockstep` — Make recipe, two test
    scripts, the Portainer compose template, and the README operator
    pull instruction.
  * Refuses to overwrite an identical pin and refuses patch-pinned
    minors (`X.Y.Z`) — both fail loudly rather than mutating partially.

For a config-only revision (nginx.conf change without a minor bump):

```bash
./scripts/bump-nginx.sh --config-revision 2 <current-minor>
```

### 3. Verify locally

```bash
make ci-pytest ci-lockstep-tests ci-nginx-config
```

`ci-nginx-config` exercises the rendered nginx.conf against the bumped
image. A directive-level regression surfaces here.

### 4. Ship

  * Open a PR. `build.yml` rebuilds the nginx image stage on push.
  * After merge, pull the new image on the live host:
    `docker pull ghcr.io/magicsunday/webtrees-nginx:<new-tag>`.
  * Close the tracking issue with a comment linking the merge commit.

## Bumping the MariaDB pin

Triggered by a `MariaDB X.Y available` issue from `check-mariadb.yml`.

### 1. Review release notes

  * https://mariadb.com/kb/en/release-notes/
  * Focus on schema-migration notes, config-format changes, removed
    SQL modes, and any item flagged for `mariadb-upgrade`. Major-minor
    moves (e.g. 11.4 → 11.8) often require `mariadb-upgrade` against
    existing data volumes.

### 2. Run the bumper

```bash
./scripts/bump-mariadb.sh <new-minor>
```

(`make bump-mariadb VERSION=<new-minor>` is equivalent but exposes
the Make-injection surface described in the trust model above.)

The script invokes `scripts/bump-mariadb.py` inside a python:3.13-slim
container, which sed-replaces every
`image: mariadb:X.Y` line in the four shipped compose sites enforced
by `installer/tests/test_mariadb_pin_lockstep`: the standalone +
traefik installer templates, the dev-mode `compose.yaml`, and the
Portainer compose template. A trailing YAML comment on the image line
is preserved.

### 3. Test the upgrade path

  * Spin up a snapshot of an existing data volume against the new pin
    in a throwaway compose stack.
  * Confirm clean startup; if the logs request `mariadb-upgrade`,
    document the upgrade command in the PR description so operators
    running stable installs know what to expect.

### 4. Verify locally + ship

```bash
make ci-pytest ci-lockstep-tests
```

Open a PR, close the tracking issue on merge.

## Bumping the Alpine pin

Triggered by an `alpine X.Y available` issue from `check-alpine.yml`.

The canonical pin is the Python constant `ALPINE_BASE_IMAGE` in
`installer/webtrees_installer/_alpine.py`. Mirror sites are scanned
by `make ci-alpine-lockstep` — Dockerfile, compose.\*.yaml, docs,
Make/scripts. The list is too large for a single sed sweep, so the
procedure is manual with the lockstep recipe as guide.

### 1. Review release notes

  * https://alpinelinux.org/releases/ — the release announcement.
  * Focus on busybox version (affects shell behaviour in entrypoint
    scripts), musl version (libc-level ABI shifts), apk index format,
    and Python / PHP package availability.

### 2. Update the canonical pin

```bash
sed -i 's/ALPINE_BASE_IMAGE = "alpine:[0-9.]\+"/ALPINE_BASE_IMAGE = "alpine:<new-minor>"/' \
    installer/webtrees_installer/_alpine.py
```

(Or edit the file directly — the constant is a single line.)

### 3. Sync the mirrors via the lockstep

```bash
make ci-alpine-lockstep
```

This lists every literal `alpine:X.Y` reference still on the old pin.
Sed-replace each one. Excluded by policy: `docs/superpowers/` (frozen
historical specs) and Dockerfile variant tags (`php:8.5-fpm-alpine`,
`nginx:1.30-alpine` — they follow their parent image's cadence).

### 4. Verify locally + ship

```bash
make ci-test
```

`ci-test` runs the full local CI bundle (pytest + lint + lockstep +
entrypoint). Open a PR; CI rebuilds every Alpine-derived image stage.

## Bumping a PHP minor

`check-php.yml` distinguishes two cases:

  * **Patch bump** (8.5.6 → 8.5.7): handled automatically by the
    workflow's digest scan + `dev/php_digests.lock` mechanism. No
    operator action required beyond approving the auto-generated PR.

  * **New minor** (8.6, 9.0): the workflow opens a tracking issue
    only. Adding a PHP minor expands the build matrix; review the
    PHP release notes for ABI / extension-availability changes, then
    add the new minor to the auto-bump fan-out in
    `.github/workflows/check-versions.yml`. A separate refactor will
    consolidate the PHP-minor list into a single source of truth.

There is no `make bump-php` target. Patch bumps are workflow-driven,
and minor bumps need a structural review that does not fit a one-shot
sed sweep.
