#!/usr/bin/env bash
# Asserts the CI tooling image pins in Make/images.mk and
# scripts/lib/images.env stay in sync (issue #120). Both files
# encode the same set of CI_IMAGE_* variables; this script extracts
# each side, sorts canonically, and diffs. A mismatch fails the
# build with the exact divergence rather than the operator
# discovering it via a half-bumped CI run weeks later.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

mk=Make/images.mk
env=scripts/lib/images.env

[ -f "$mk" ] || { echo "::error::$mk not found" >&2; exit 1; }
[ -f "$env" ] || { echo "::error::$env not found" >&2; exit 1; }

# Extract `CI_IMAGE_X := value` from Make/images.mk and
# `CI_IMAGE_X="value"` from images.env, normalising both to the
# same `NAME=value` shape for sort+diff. The Make form uses ` := `
# with mandatory single space; the env form uses `=` with no
# surrounding whitespace. Both sides strip surrounding quotes.
mk_pairs=$(grep -E '^CI_IMAGE_[A-Z]+ +:= ' "$mk" \
    | sed -E 's/^([A-Z_]+) +:= +(.*)$/\1=\2/' \
    | sort)

env_pairs=$(grep -E '^CI_IMAGE_[A-Z]+="[^"]+"$' "$env" \
    | sed -E 's/^([A-Z_]+)="(.*)"$/\1=\2/' \
    | sort)

if [ "$mk_pairs" != "$env_pairs" ]; then
    echo "::error::CI image pins drifted between $mk and $env." >&2
    echo "::error::Run \`diff\` between the two files and reconcile." >&2
    echo "--- $mk" >&2
    printf '%s\n' "$mk_pairs" >&2
    echo "--- $env" >&2
    printf '%s\n' "$env_pairs" >&2
    exit 1
fi
