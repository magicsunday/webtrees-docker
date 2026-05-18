# =============================================================================
# Centralised CI tooling image pins.
# =============================================================================
#
# Single source of truth for every container image used by ci-* recipes and
# scripts/ helpers. Bump an image here and `scripts/lib/images.env` in
# lockstep — `ci-images-lockstep` enforces the two stay byte-identical, so
# a future tag change in either file fails CI until both are updated.
#
# Rationale (#120): ci.mk used to inline `python:3.13-slim` in 5 places,
# `hadolint/hadolint:latest` in 2 places, etc. A tag bump meant grep-fix
# the same literal across many recipes, and new tooling targets had no
# established pin to reuse. Centralising mirrors how COMPOSE_BUILD /
# COMPOSE_BUILD_ROOT in the top-level Makefile already work for the dev
# tooling chain.
#
# Pin discipline: prefer immutable digests for reproducibility once the
# tag stabilises; rolling tags (`:latest`, `:stable`) stay only on tools
# where the upstream maintains a one-true-current-stable channel
# (hadolint, shellcheck) and never publishes breaking changes outside
# major version bumps.

# Python toolchain (pytest, ruff, mypy, vulture, pylint). 3.13-slim is the
# debian-slim base; bumps must update the installer Dockerfile's FROM
# pin too — `ci-python-pin-lockstep` enforces.
CI_IMAGE_PYTHON   := python:3.13-slim

# jq CLI for the versions-manifest queries in ci-* targets and the
# scripts/check-*.sh lockstep helpers. ghcr.io/jqlang/jq is the
# official jq mirror image, semver-tagged.
CI_IMAGE_JQ       := ghcr.io/jqlang/jq:latest

# Hadolint (Dockerfile lint). Upstream :latest tracks the most recent
# stable release; not pinned to a digest because hadolint's release
# cadence is monthly with no incompat changes.
CI_IMAGE_HADOLINT := hadolint/hadolint:latest

# Shellcheck (shell-script lint). `:stable` is the upstream-maintained
# channel for the latest stable release; CI runs it against every tracked
# shell script via a shebang-scan in ci-shellcheck.
CI_IMAGE_SHELLCHK := koalaman/shellcheck:stable

# yamllint for workflow + compose YAML. cytopia/yamllint is a minimal
# debian-slim wrapper around the upstream Python package.
CI_IMAGE_YAMLLINT := cytopia/yamllint:latest

# =============================================================================
# CI run wrappers — full `docker run` invocations consumers expand verbatim.
# =============================================================================
#
# Mirrors the top-level Makefile's COMPOSE_BUILD_BASE pattern: one
# private base, many public variants derive from it. Recipes spell
# out the tool-specific command; everything before is a single
# variable expansion. Adding a future wrapper for a new tool reuses
# the same shape so a docker-run flag change (e.g. --user, --network)
# is one edit (#120).

_CI_RUN_BASE := docker run --rm

# Shared Python skeleton: installer/ mounted at /app, pip-cache
# volume, --entrypoint sh. The two public variants append extra
# flags + the trailing image pin.
_CI_RUN_PYTHON_BASE := $(_CI_RUN_BASE) \
	-v "$(PWD)/installer:/app" \
	-v webtrees-ci-pip-cache:/root/.cache/pip \
	-w /app \
	--entrypoint sh

# ci-{ruff,mypy,vulture,cpd}: installer-only.
CI_RUN_PYTHON := $(_CI_RUN_PYTHON_BASE) $(CI_IMAGE_PYTHON)

# ci-pytest: adds repo-root :ro + WT_REPO_ROOT so lockstep tests can
# walk the actual repo from /repo/ instead of pathlib jumps out of
# installer/.
CI_RUN_PYTHON_WITH_REPO := $(_CI_RUN_PYTHON_BASE) \
	-v "$(PWD):/repo:ro" \
	-e WT_REPO_ROOT=/repo \
	$(CI_IMAGE_PYTHON)

# jq against dev/versions.json + dev/php-versions.json.
CI_RUN_JQ := $(_CI_RUN_BASE) \
	-v "$(PWD)/dev:/d:ro" \
	-w /d \
	$(CI_IMAGE_JQ)

# Hadolint reads the Dockerfile from stdin (`-i`).
CI_RUN_HADOLINT := $(_CI_RUN_BASE) -i $(CI_IMAGE_HADOLINT)

# Shellcheck: invoked as `xargs … $(CI_RUN_SHELLCHK) -x` with the
# file list piped in, so repo is bind-mounted at /work.
CI_RUN_SHELLCHK := $(_CI_RUN_BASE) \
	-v "$(PWD):/work" \
	-w /work \
	$(CI_IMAGE_SHELLCHK)

# yamllint against compose + workflow paths.
CI_RUN_YAMLLINT := $(_CI_RUN_BASE) \
	-v "$(PWD):/work" \
	-w /work \
	$(CI_IMAGE_YAMLLINT)
