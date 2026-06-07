#!/usr/bin/env bash
# Operator entry point for the nginx pin bump. Routes argv straight to
# the Python implementation inside the pinned python container via the
# shared _bump-runner.sh — no Make involvement, no $(shell …)/:=/!=/
# CURDIR= command-line overrides to dodge (see _bump-runner.sh for the
# full rationale).
#
# Usage:
#   ./scripts/bump/bump-nginx.sh [--config-revision N] <new-minor>
#   e.g. ./scripts/bump/bump-nginx.sh 1.32
#        ./scripts/bump/bump-nginx.sh --config-revision 2 1.30
#   Flags must precede the positional new-minor argument.

set -euo pipefail

# shellcheck source=scripts/bump/_bump-runner.sh
source "$(dirname "$0")/_bump-runner.sh"

bump_run scripts/bump/bump-nginx.py "$@"
