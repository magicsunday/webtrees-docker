#!/usr/bin/env bash
# Asserts the nginx healthcheck start_period matches across the dev
# compose, both installer templates, and the Portainer template.
# Invoked by `make ci-healthcheck-lockstep`.
#
# The nginx healthcheck stanza ships in four places: the dev-stack
# root compose.yaml, the Portainer template (templates/portainer/
# compose.yaml), and the two wizard-rendered installer templates
# (compose.standalone.j2 + compose.traefik.j2). They must all agree
# on start_period; a drift means dev-stack operators get a different
# bootstrap-tolerance window than wizard-rendered production stacks.
# The two installer templates are already pinned via test_render_*
# (parametrised over both proxy modes); this check covers all four.
#
# yq parses YAML structurally so the three start_periods on the db /
# phpfpm / nginx healthchecks do not collide — we always pull
# services.nginx.healthcheck.start_period. mikefarah/yq runs in a
# throwaway container so the host needs no yq install.
#
# Issue #141: both installer Jinja templates now consume a shared
# `nginx_healthcheck()` macro from `_compose_macros.j2` — the nginx
# start_period literal lives in the macro file. The macro file is
# the single source of truth for the rendered .j2 outputs; the
# lockstep targets it directly via sed (Jinja braces still preclude
# yq). compose.yaml (dev stack) and templates/portainer/compose.yaml
# remain hand-maintained YAML and are parsed with yq.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

yq_image="mikefarah/yq:latest"

root_value=$(docker run --rm -v "$repo_root:/work" -w /work "$yq_image" \
    '.services.nginx.healthcheck.start_period' compose.yaml)
portainer_value=$(docker run --rm -v "$repo_root:/work" -w /work "$yq_image" \
    '.services.nginx.healthcheck.start_period' templates/portainer/compose.yaml)
# `|| true` after the grep prevents pipefail from aborting the
# assignment when the template silently drops the `start_period:`
# key — the explicit empty-value check below is the canonical error
# surface. Without this, set -euo pipefail would short-circuit the
# script with no `::error::` annotation.
# `sed -n '/nginx_healthcheck/,/endmacro/p'` walks from the macro
# header to its terminator; `grep -E '^[[:space:]]+start_period:'`
# then picks the line. The macro file is a single source of truth
# for both standalone + traefik, so one extraction covers both.
# `|| true` after the grep prevents pipefail from aborting the
# assignment when the macro silently drops the `start_period:` key.
# Anchor the sed range against the Jinja `{%- macro nginx_healthcheck(`
# header AND `{%- endmacro -%}` terminator rather than substring
# matches — otherwise a stray comment containing "macro nginx_healthcheck"
# above the real definition would shift the start address.
macro_value=$(sed -n '/{%- macro nginx_healthcheck(/,/{%- endmacro -%}/p' \
    installer/webtrees_installer/templates/_compose_macros.j2 \
    | { grep -E '^[[:space:]]+start_period:' || true; } \
    | head -1 | awk '{print $2}')

if [ -z "$root_value" ] || [ "$root_value" = "null" ] \
    || [ -z "$portainer_value" ] || [ "$portainer_value" = "null" ] \
    || [ -z "$macro_value" ]; then
    echo "::error::healthcheck start_period not found (root='$root_value', portainer='$portainer_value', macro='$macro_value')" >&2
    exit 1
fi

if [ "$root_value" != "$macro_value" ] || [ "$root_value" != "$portainer_value" ]; then
    echo "::error::nginx healthcheck start_period drift — compose.yaml='$root_value' vs portainer='$portainer_value' vs macro='$macro_value'" >&2
    exit 1
fi

echo "  canonical start_period: $root_value"
