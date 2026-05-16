#!/usr/bin/env bash
# Asserts every `alpine:X.Y` reference in shipped surfaces matches the
# central pin from ALPINE_BASE_IMAGE. Invoked by `make ci-alpine-
# lockstep`.
#
# Single-source-of-truth check: ALPINE_BASE_IMAGE in
# webtrees_installer/_alpine.py is canonical. Every literal
# `alpine:X.Y[.Z]` reference in live code, runtime configs, docs and
# Make/scripts must match it. A partial bump that updates the constant
# but forgets one consumer (or vice versa) trips this check.
#
# Scoped to surfaces that ship to the operator. Excluded:
#   * `docs/superpowers/` — historical specs/plans, frozen point-in-
#     time records.
#   * Dockerfile variant tags (`php:8.5-fpm-alpine`,
#     `nginx:1.30-alpine`) — follow their parent image's release
#     cadence; out of scope.
#
# Shape assertion on the pin itself: `alpine:X.Y` (no patch). Pin
# policy is enforced here, not just on convention. A future maintainer
# adding a patch suffix (X.Y.Z) would fail this check loudly.
# The parser script handles canonical/Final[str]/indented/single-
# quoted variants of the assignment so a benign reformat of
# _alpine.py doesn't break this recipe; tests/test-lockstep.sh
# exercises the failure paths.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

pinned=$(./scripts/parse-alpine-pin.sh)
echo "  canonical pin: $pinned"

echo "$pinned" | grep -qE '^alpine:[0-9]+\.[0-9]+$' || {
    echo "::error::ALPINE_BASE_IMAGE='$pinned' violates the minor-only pin policy (expected 'alpine:X.Y')" >&2
    exit 1
}

drifted=$(find installer/webtrees_installer Make docs Dockerfile installer/Dockerfile templates -type f \
        \( -name '*.py' -o -name '*.j2' -o -name '*.md' -o -name '*.mk' -o -name '*.sh' -o -name 'Dockerfile*' -o -name 'compose.yaml' \) \
        -not -path 'docs/superpowers/*' \
        -print0 2>/dev/null \
    | xargs -0 grep -hEo 'alpine:[0-9]+\.[0-9]+(\.[0-9]+)?' 2>/dev/null \
    | sort -u | grep -vFx "$pinned" || true)

if [ -n "$drifted" ]; then
    echo "::error::Alpine pin drift detected — these references diverge from ALPINE_BASE_IMAGE='$pinned':" >&2
    echo "$drifted" >&2
    exit 1
fi
