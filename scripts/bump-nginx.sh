#!/usr/bin/env bash
# Operator entry point for the nginx pin bump. Routes argv straight
# to the Python implementation inside a python:3.13-slim container —
# no Make involvement, no $(shell …)/:=/!=/CURDIR= command-line
# overrides to dodge.
#
# Usage:
#   ./scripts/bump-nginx.sh [--config-revision N] <new-minor>
#   e.g. ./scripts/bump-nginx.sh 1.32
#        ./scripts/bump-nginx.sh --config-revision 2 1.30
#   Flags must precede the positional new-minor argument.
#
# Make's bump-nginx target delegates here too, so operators may use
# either entry point; this script form is recommended whenever the
# invocation came from an untrusted source (chat, README, gist) since
# Make 4.4+ evaluates command-line `$(shell …)` / `:=` / `!=` /
# `CURDIR=` assignments at parse time and no in-Makefile guard can
# defeat them.
#
# `--user $(id -u):$(id -g)` makes container-side mutations inherit
# the operator's UID/GID. Without it, dev/nginx-version.json + every
# sed'd mirror site would land owned by root:root on the NAS host,
# blocking `git add` without sudo.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

exec docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$repo_root:/app" \
    -w /app \
    python:3.13-slim \
    python3 scripts/bump-nginx.py "$@"
