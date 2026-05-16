#!/usr/bin/env bash
# Operator entry point for the MariaDB pin bump. Routes argv straight
# to the Python implementation inside a python:3.13-slim container —
# no Make involvement, no $(shell …)/:=/!=/CURDIR= command-line
# overrides to dodge.
#
# Usage:
#   ./scripts/bump-mariadb.sh <new-minor>
#   e.g. ./scripts/bump-mariadb.sh 11.9
#
# Make's bump-mariadb target delegates here too, so operators may use
# either entry point; this script form is recommended whenever the
# invocation came from an untrusted source (chat, README, gist) since
# Make 4.4+ evaluates command-line `$(shell …)` / `:=` / `!=` /
# `CURDIR=` assignments at parse time and no in-Makefile guard can
# defeat them.
#
# `--user $(id -u):$(id -g)` makes container-side mutations inherit
# the operator's UID/GID. Without it, the four sed'd compose sites
# (standalone + traefik templates, dev compose, Portainer compose)
# would land owned by root:root on the NAS host, blocking `git add`
# without sudo.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

exec docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$repo_root:/app" \
    -w /app \
    python:3.13-slim \
    python3 scripts/bump-mariadb.py "$@"
