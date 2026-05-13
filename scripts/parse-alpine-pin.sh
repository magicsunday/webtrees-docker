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
#   scripts/parse-alpine-pin.sh [path-to-_alpine.py]
#   default path: installer/webtrees_installer/_alpine.py

set -o errexit -o nounset -o pipefail

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
# The extractor is anchored on the literal `alpine:X.Y[.Z]` shape inside
# quotes — anything else (unquoted RHS, non-alpine image, truncated value)
# yields empty stdout from sed's -n + /p, which the empty-string check
# below converts into a clear `::error::` annotation.
#
# `|| true` swallows grep's no-match exit so the explicit empty-string
# check still runs and emits a diagnostic rather than `set -e` aborting
# with no output.
pin=$(grep -E '^[[:space:]]*ALPINE_BASE_IMAGE([[:space:]]*:[^=]+)?[[:space:]]*=' "$file" \
    | head -n 1 \
    | sed -nE 's/^[^=]*=[[:space:]]*["'\'']([[:space:]]*alpine:[0-9]+\.[0-9]+(\.[0-9]+)?[[:space:]]*)["'\''].*/\1/p' \
    || true)
# Strip any whitespace the quoted value carried.
pin=$(printf '%s' "$pin" | tr -d '[:space:]')

[ -n "$pin" ] || {
    echo "::error::Could not parse ALPINE_BASE_IMAGE from $file" >&2
    exit 1
}

printf '%s\n' "$pin"
