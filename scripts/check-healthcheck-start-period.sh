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
# The two .j2 templates use sed because Jinja braces (`{% if %}`)
# break a pure YAML parser. The `sed -n '/nginx:/,$p' | head -1`
# pattern assumes nginx is the LAST service in both templates so
# `head -1` reliably lands on nginx's start_period. If a future
# template appends a service after nginx, tighten the sed range to
# `/^    nginx:/,/^    [a-z][a-z_-]*:$/` and re-run ci-lockstep-tests
# (test-lockstep.sh's drift fixtures pin both templates and would
# trip if the extracted value silently regresses).

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
standalone_value=$(sed -n '/^    nginx:/,$p' \
    installer/webtrees_installer/templates/compose.standalone.j2 \
    | { grep -E '^[[:space:]]+start_period:' || true; } \
    | head -1 | awk '{print $2}')
traefik_value=$(sed -n '/^    nginx:/,$p' \
    installer/webtrees_installer/templates/compose.traefik.j2 \
    | { grep -E '^[[:space:]]+start_period:' || true; } \
    | head -1 | awk '{print $2}')

if [ -z "$root_value" ] || [ "$root_value" = "null" ] \
    || [ -z "$portainer_value" ] || [ "$portainer_value" = "null" ] \
    || [ -z "$standalone_value" ] || [ -z "$traefik_value" ]; then
    echo "::error::healthcheck start_period not found (root='$root_value', portainer='$portainer_value', standalone='$standalone_value', traefik='$traefik_value')" >&2
    exit 1
fi

if [ "$root_value" != "$standalone_value" ] || [ "$root_value" != "$traefik_value" ] || [ "$root_value" != "$portainer_value" ]; then
    echo "::error::nginx healthcheck start_period drift — compose.yaml='$root_value' vs portainer='$portainer_value' vs standalone='$standalone_value' vs traefik='$traefik_value'" >&2
    exit 1
fi

echo "  canonical start_period: $root_value"
