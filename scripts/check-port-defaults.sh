#!/usr/bin/env bash
# Asserts _DEFAULT_PORT / _FALLBACK_PORT mirrors agree across every
# documented site. Invoked by `make ci-port-default-lockstep`.
#
# Source of truth: installer/webtrees_installer/flow.py:_DEFAULT_PORT
# and _FALLBACK_PORT. The mirror block at flow.py:74-82 documents
# every file that must carry the same literal; this target enforces
# the discipline programmatically (mirrors ci-alpine-lockstep).
#
# Drift has happened before — docs/env-vars.md briefly fell back to
# `80` during the 28k-band introduction and stayed there until a
# retrospective audit caught it. With this check on every commit, the
# next bump moves all sites or trips the failure-path test.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

pair=$(./scripts/parse-port-defaults.sh)
default_port=${pair%:*}
fallback_port=${pair#*:}
echo "  canonical default: $default_port, fallback: $fallback_port"

default_sites="compose.publish.yaml install upgrade switch README.md docs/customizing.md docs/developing.md docs/env-vars.md templates/portainer/compose.yaml"
fallback_sites="README.md"

missing=""
for f in $default_sites; do
    grep -qFw "$default_port" "$f" 2>/dev/null \
        || missing="$missing $f(default)"
done
for f in $fallback_sites; do
    grep -qFw "$fallback_port" "$f" 2>/dev/null \
        || missing="$missing $f(fallback)"
done

if [ -n "$missing" ]; then
    echo "::error::Port-default lockstep drift — these sites do not carry the canonical value:$missing" >&2
    exit 1
fi
