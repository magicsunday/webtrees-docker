#!/usr/bin/env bash
# Pre-pulls a docker image and emits an actionable `::error::` annotation
# when the pull fails. Shared by `ci-entrypoint` and `ci-nginx-config`
# in Make/ci.mk so each new ci-* target that needs the same guard can
# drop the inline `docker pull … || { echo ::error… ; exit 1; }` block.
#
# Usage:
#   ./scripts/lib/pull-or-fail.sh ghcr.io/magicsunday/webtrees-php:X.Y.Z-phpA.B
#
# Exit codes:
#   0  pull succeeded
#   1  pull failed (or bare-tag reference) — annotation already emitted on stderr
#   2  bad usage (missing image argument)

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "::error::pull-or-fail: requires exactly one image reference" >&2
    exit 2
fi

image=$1

# A bare-tag reference (`<repo>:`) is the most common upstream-error
# shape — e.g. a `$(LATEST_PHP_TAG)` jq query returned empty and the
# caller pasted nothing after the `:`. Surface it cleanly before
# docker would have failed with the cryptic "invalid reference format".
case "$image" in
    *:) echo "::error::pull-or-fail: image reference '$image' is missing a tag" >&2; exit 1 ;;
esac

if ! docker pull "$image" >/dev/null; then
    echo "::error::docker pull failed for $image" >&2
    exit 1
fi
