#!/usr/bin/env bash
# Operator entry point for the MariaDB pin bump. Routes argv straight
# to the Python implementation inside the pinned python container via
# the shared _bump-runner.sh — no Make involvement, no $(shell …)/:=/!=/
# CURDIR= command-line overrides to dodge (see _bump-runner.sh for the
# full rationale).
#
# Usage:
#   ./scripts/bump/bump-mariadb.sh <new-minor>
#   e.g. ./scripts/bump/bump-mariadb.sh 11.9
#
# Bumps the mariadb pin across the four sed'd compose sites (standalone
# + traefik templates, dev compose, Portainer compose).

set -euo pipefail

# shellcheck source=scripts/bump/_bump-runner.sh
source "$(dirname "$0")/_bump-runner.sh"

bump_run scripts/bump/bump-mariadb.py "$@"
