#!/usr/bin/env bash
#
# Print the canonical APP_PORT defaults declared in
# installer/webtrees_installer/flow.py:
#   <default-port>:<fallback-port>
# (e.g. `28080:28081`).
#
# Designed so a reasonable reformat of the source file — optional
# `: int` / `: Final[int]` annotation, leading indentation — keeps the
# parser working. A parse failure exits 1 with an `::error::`
# annotation so the caller (ci-port-default-lockstep on every commit)
# fails loudly instead of silently emitting empty values downstream.
#
# Usage:
#   scripts/parse-port-defaults.sh [path-to-flow.py]
#   default path: installer/webtrees_installer/flow.py

set -o errexit -o nounset -o pipefail

file="${1:-installer/webtrees_installer/flow.py}"

[ -f "$file" ] || {
    echo "::error::Port-defaults source not found: $file" >&2
    exit 1
}

# Accepts:
#   _DEFAULT_PORT = 28080
#   _DEFAULT_PORT: int = 28080
#   _DEFAULT_PORT: Final[int] = 28080
# Same shape for _FALLBACK_PORT.
extract() {
    local symbol="$1"
    grep -E "^[[:space:]]*${symbol}([[:space:]]*:[^=]+)?[[:space:]]*=" "$file" \
        | head -n 1 \
        | sed -nE 's/^[^=]*=[[:space:]]*([0-9]+).*/\1/p' \
        || true
}

default_port=$(extract "_DEFAULT_PORT")
fallback_port=$(extract "_FALLBACK_PORT")

[ -n "$default_port" ] || {
    echo "::error::Could not parse _DEFAULT_PORT from $file" >&2
    exit 1
}
[ -n "$fallback_port" ] || {
    echo "::error::Could not parse _FALLBACK_PORT from $file" >&2
    exit 1
}

# Invariant: default and fallback must differ. They model "try this
# port, fall back to the next one on conflict" — collapsing them to
# the same literal breaks the fallback semantics in flow.py:_resolve_port
# (the `if port == _FALLBACK_PORT` branch never fires) and would
# silently pass an otherwise-correct mirror scan.
if [ "$default_port" = "$fallback_port" ]; then
    echo "::error::_DEFAULT_PORT and _FALLBACK_PORT must differ (both = $default_port)" >&2
    exit 1
fi

printf '%s:%s\n' "$default_port" "$fallback_port"
