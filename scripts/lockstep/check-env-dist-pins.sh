#!/usr/bin/env bash
# Asserts .env.dist's webtrees/nginx version pins mirror their dev/
# canonical sources. Invoked by `make ci-env-dist-pins-lockstep`.
#
# Mirrored pairs:
#   .env.dist WEBTREES_VERSION         <- versions.json webtrees of the row carrying "latest"
#   .env.dist WEBTREES_NGINX_VERSION   <- dev/nginx-version.json .tag
#   .env.dist NGINX_CONFIG_REVISION    <- dev/nginx-version.json .config_revision
#   .env.dist NGINX_BASE               <- dev/nginx-version.json .nginx_base
#   .env.dist PHP_VERSION              <- MUST be a member of dev/php-versions.json .supported
#
# Drift mode this catches: operator bumps dev/nginx-version.json (or
# dev/versions.json or dev/php-versions.json) but forgets to refresh
# .env.dist. A fresh checkout initialised via `cp .env.dist .env` then
# runs the old pin while the canonical source moved on; compose silently
# keeps the previous tag alive across release. The PHP_VERSION case
# survives `.supported` drift: dropping 8.3 from `.supported` leaves
# `.env.dist`'s documented default pointing at an unsupported minor.

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
# shellcheck source=scripts/lib/php-versions-lib.sh
source "$(dirname "$0")/../lib/php-versions-lib.sh"
lockstep_init "$@"

env_dist=".env.dist"
[ -f "$env_dist" ] || {
    echo "::error::$env_dist is missing" >&2
    exit 1
}

read_pin() {
    local key=$1
    local matches
    # Strict `<KEY>=<value>` shape; the regex anchors at start-of-line so
    # commented-out lines (`# WEBTREES_VERSION=2.x`) cannot satisfy it.
    # Count matches first — docker compose's .env loader treats the LAST
    # occurrence as authoritative, but bash's `head -n1` would pick the
    # FIRST. Fail loud on duplicates instead of silently disagreeing
    # with compose's effective value.
    matches=$(grep -cE "^${key}=" "$env_dist" || true)
    if [ "$matches" -eq 0 ]; then
        echo "::error::$env_dist is missing required key '$key'" >&2
        exit 1
    fi
    if [ "$matches" -gt 1 ]; then
        echo "::error::$env_dist defines '$key' $matches times — docker compose would take the last; refuse ambiguity" >&2
        exit 1
    fi
    grep -E "^${key}=" "$env_dist" | cut -d= -f2-
}

env_webtrees=$(read_pin WEBTREES_VERSION)
env_nginx_tag=$(read_pin WEBTREES_NGINX_VERSION)
env_nginx_rev=$(read_pin NGINX_CONFIG_REVISION)
env_nginx_base=$(read_pin NGINX_BASE)
env_php=$(read_pin PHP_VERSION)

assert_jq_parseable "$repo_root" versions.json
assert_jq_parseable "$repo_root" nginx-version.json
assert_jq_parseable "$repo_root" php-versions.json

# Schema-shape gate before the union extraction so a pre-migration
# flat-array `.supported` (or any other malformed shape) fails with
# a clear schema diagnostic. Mirrors the gate at the top of
# check-php-versions.sh.
ci_validate_php_supported_shape "$repo_root"

# Source-of-truth webtrees: the row carrying the "latest" tag in
# versions.json. ci-versions-latest-semver-max-lockstep separately
# asserts that row IS the semver-max row, so here we just read the
# "latest"-marked value as-is.
expected_webtrees=$(ci_run_jq "$repo_root" \
    -r '[.[] | select(.tags | any(. == "latest")) | .webtrees] | first // ""' versions.json)

if [ -z "$expected_webtrees" ]; then
    echo "::error::dev/versions.json carries no row with the 'latest' tag — cannot derive expected .env.dist WEBTREES_VERSION" >&2
    exit 1
fi

expected_nginx_parts=$(ci_run_jq "$repo_root" \
    -r '[.tag // "", (.config_revision // "" | tostring), .nginx_base // ""] | @tsv' nginx-version.json)
IFS=$'\t' read -r expected_nginx_tag expected_nginx_rev expected_nginx_base <<<"$expected_nginx_parts"

if [ "$env_webtrees" != "$expected_webtrees" ]; then
    echo "::error::$env_dist WEBTREES_VERSION drift: have '$env_webtrees', expected '$expected_webtrees' (from dev/versions.json 'latest' tag)" >&2
    exit 1
fi

if [ "$env_nginx_tag" != "$expected_nginx_tag" ]; then
    echo "::error::$env_dist WEBTREES_NGINX_VERSION drift: have '$env_nginx_tag', expected '$expected_nginx_tag' (from dev/nginx-version.json .tag)" >&2
    exit 1
fi

if [ "$env_nginx_rev" != "$expected_nginx_rev" ]; then
    echo "::error::$env_dist NGINX_CONFIG_REVISION drift: have '$env_nginx_rev', expected '$expected_nginx_rev' (from dev/nginx-version.json .config_revision)" >&2
    exit 1
fi

if [ "$env_nginx_base" != "$expected_nginx_base" ]; then
    echo "::error::$env_dist NGINX_BASE drift: have '$env_nginx_base', expected '$expected_nginx_base' (from dev/nginx-version.json .nginx_base)" >&2
    exit 1
fi

# `.supported` is a per-webtrees-minor map (see check-php-versions.sh
# for the schema and rationale). The .env.dist default is a single PHP
# pin used by any webtrees minor, so membership is checked against the
# UNION of every value array across keys — routed through the shared
# helper so a future schema migration touches one place, not three.
php_supported_set=$(ci_php_supported_union "$repo_root" | tr ',' ' ')

php_in_supported=0
for minor in $php_supported_set; do
    if [ "$minor" = "$env_php" ]; then
        php_in_supported=1
        break
    fi
done

if [ "$php_in_supported" -ne 1 ]; then
    echo "::error::$env_dist PHP_VERSION drift: have '$env_php', not in dev/php-versions.json .supported set ($php_supported_set)" >&2
    exit 1
fi

echo "  .env.dist pins mirror dev/: webtrees=$env_webtrees, nginx=$env_nginx_tag (base $env_nginx_base, rev $env_nginx_rev), php=$env_php (in .supported)"
