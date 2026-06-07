#!/usr/bin/env bash
# Asserts dev/nginx-version.json `.tag` is derivable from `.nginx_base`
# and `.config_revision`. Invoked by `make ci-nginx-tag-derivation-lockstep`.
#
# Derivation rule:   tag == "<nginx_base>-r<config_revision>"
#   e.g. nginx_base="1.30", config_revision=1 → tag="1.30-r1"
#
# `.tag` is a cached value that downstream consumers (build.yml,
# WEBTREES_NGINX_VERSION in .env.dist) read directly. A hand-edit that
# bumps `.config_revision` 1 → 2 without updating `.tag` leaves the
# cached form stale and the published image tag silently drifts from
# the source-of-truth pair. This guard re-derives the value and fails
# loud if the cached form disagrees.

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

assert_jq_parseable "$repo_root" nginx-version.json

# Pull all three fields in one jq call so any missing key surfaces with
# a single error rather than three independent ones. The `// "<missing>"`
# sentinel must be applied BEFORE `tostring` on numeric fields — jq's
# `tostring` on null yields the literal "null", which would mask the
# missing-field guard.
parts=$(ci_run_jq "$repo_root" \
    -r '[.nginx_base // "<missing>", (.config_revision // "<missing>" | tostring), .tag // "<missing>"] | @tsv' \
    nginx-version.json) || {
    echo "::error::docker run for nginx-version.json field extraction failed" >&2
    exit 1
}

IFS=$'\t' read -r nginx_base config_revision tag <<<"$parts"

for field in nginx_base config_revision tag; do
    if [ "${!field}" = "<missing>" ] || [ -z "${!field}" ]; then
        echo "::error::dev/nginx-version.json is missing required field '$field'" >&2
        exit 1
    fi
done

expected="${nginx_base}-r${config_revision}"
if [ "$tag" != "$expected" ]; then
    echo "::error::dev/nginx-version.json .tag drift: have '$tag', expected '$expected' (derived from .nginx_base='$nginx_base' + .config_revision=$config_revision)" >&2
    exit 1
fi

echo "  nginx tag derivation: $tag (= $nginx_base-r$config_revision)"
