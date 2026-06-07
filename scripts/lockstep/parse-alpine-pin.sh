#!/usr/bin/env bash
#
# Print the canonical Alpine pin (`alpine:X.Y`) declared in
# installer/webtrees_installer/_alpine.py. Designed so a reasonable
# reformat of the source file — optional `: Type` annotation, leading
# indentation, single OR double quotes — keeps the parser working.
#
# A parse failure exits 1 with an `::error::` annotation, so the caller
# (check-alpine.yml on a daily cron, ci-alpine-lockstep on every commit)
# fails loudly instead of silently emitting an empty pin downstream.
#
# Usage:
#   scripts/lockstep/parse-alpine-pin.sh [path-to-_alpine.py]
#   default path: installer/webtrees_installer/_alpine.py

set -o errexit -o nounset -o pipefail

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"

file="${1:-installer/webtrees_installer/_alpine.py}"

[ -f "$file" ] || {
    echo "::error::Alpine pin source not found: $file" >&2
    exit 1
}

# Accepts:
#   ALPINE_BASE_IMAGE = "alpine:3.23"
#   ALPINE_BASE_IMAGE: Final[str] = "alpine:3.23"
#       ALPINE_BASE_IMAGE = 'alpine:3.23'
#
# parse_python_constant returns the matched assignment line (empty on no
# match — its internal `|| true` keeps `set -e` from aborting). The sed
# then pins the value to the literal `alpine:X.Y[.Z]` shape inside
# quotes — anything else (unquoted RHS, non-alpine image, truncated
# value) yields empty stdout from sed's -n + /p, which the empty-string
# check below converts into a clear `::error::` annotation.
pin=$(parse_python_constant "$file" ALPINE_BASE_IMAGE \
    | sed -nE 's/^[^=]*=[[:space:]]*["'\'']([[:space:]]*alpine:[0-9]+\.[0-9]+(\.[0-9]+)?[[:space:]]*)["'\''].*/\1/p')
# Strip any whitespace the quoted value carried.
pin=$(printf '%s' "$pin" | tr -d '[:space:]')

[ -n "$pin" ] || {
    echo "::error::Could not parse ALPINE_BASE_IMAGE from $file" >&2
    exit 1
}

printf '%s\n' "$pin"
