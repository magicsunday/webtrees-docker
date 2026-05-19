#!/usr/bin/env bash
# Asserts every `ARG <KEY>=<value>` default in Dockerfile matches the
# matching pin in .env.dist for the keys that operators can override at
# build time. Invoked by `make ci-dockerfile-arg-defaults-lockstep`.
#
# Why: the build pipeline always passes `--build-arg KEY=…` so the
# defaults are dead in CI. But anyone running `docker build .` locally
# (or `make build` without the wizard) silently bakes in whatever
# Dockerfile defaults still carry, regardless of what dev/*.json /
# .env.dist say. This guard pins both surfaces in lockstep.
#
# Audited keys (one row per file-pair line):
#   PHP_VERSION          <- .env.dist PHP_VERSION
#   WEBTREES_VERSION     <- .env.dist WEBTREES_VERSION
#   NGINX_BASE           <- .env.dist's WEBTREES_NGINX_VERSION prefix (before `-r`)
#   NGINX_CONFIG_REVISION <- .env.dist NGINX_CONFIG_REVISION

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

env_dist=".env.dist"
dockerfile="Dockerfile"
[ -f "$env_dist" ] || { echo "::error::$env_dist is missing" >&2; exit 1; }
[ -f "$dockerfile" ] || { echo "::error::$dockerfile is missing" >&2; exit 1; }

read_env_dist_pin() {
    local key=$1
    grep -E "^${key}=" "$env_dist" | head -n1 | cut -d= -f2-
}

# Splits .env.dist's `WEBTREES_NGINX_VERSION=<base>-r<rev>` into base.
read_env_dist_nginx_base() {
    local tag base
    tag=$(read_env_dist_pin WEBTREES_NGINX_VERSION)
    base=${tag%-r*}
    if [ -z "$base" ] || [ "$base" = "$tag" ]; then
        echo "::error::$env_dist WEBTREES_NGINX_VERSION='$tag' is missing the '-rN' suffix" >&2
        exit 1
    fi
    printf '%s' "$base"
}

# Asserts every `ARG <key>=<...>` line in Dockerfile carries the same
# default. Multiple sites are fine (the Dockerfile defines the same ARG
# in several stages by design) — they MUST agree byte-identical with
# each other AND with $expected.
assert_arg_default() {
    local key=$1 expected=$2 line value sites
    local mismatched=0
    sites=0

    while IFS= read -r line; do
        sites=$((sites + 1))
        value=${line#*=}
        if [ "$value" != "$expected" ]; then
            echo "::error::$dockerfile carries 'ARG ${key}=${value}', expected '${key}=${expected}' (from $env_dist)" >&2
            mismatched=1
        fi
    done < <(grep -E "^ARG ${key}=" "$dockerfile" || true)

    if [ "$sites" -eq 0 ]; then
        echo "::error::$dockerfile has no 'ARG ${key}=...' line — expected at least one" >&2
        exit 1
    fi
    [ "$mismatched" -eq 0 ] || exit 1
    echo "  ARG ${key}: ${sites} site(s), all = '${expected}'"
}

assert_arg_default PHP_VERSION           "$(read_env_dist_pin PHP_VERSION)"
assert_arg_default WEBTREES_VERSION      "$(read_env_dist_pin WEBTREES_VERSION)"
assert_arg_default NGINX_BASE            "$(read_env_dist_nginx_base)"
assert_arg_default NGINX_CONFIG_REVISION "$(read_env_dist_pin NGINX_CONFIG_REVISION)"
