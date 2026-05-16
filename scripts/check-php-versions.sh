#!/usr/bin/env bash
# Asserts dev/versions.json has exactly one row per supported PHP minor
# per webtrees minor. Invoked by `make ci-php-versions-lockstep`.
#
# The single source of truth for supported PHP minors is
# dev/php-versions.json `.supported`. dev/versions.json carries the
# actual catalog rows the build matrix consumes; for every unique
# webtrees minor in the catalog, the set of PHP values MUST equal
# `supported` exactly (no missing minor, no extra).
#
# Drift modes this catches:
#   * Operator bumps `supported` from [8.3,8.4,8.5] to [8.4,8.5,8.6]
#     but forgets to add the 8.6 rows to versions.json — the auto-
#     bump cron would then ship inconsistent matrices on the next
#     webtrees release. Caught here.
#   * Operator hand-edits versions.json to drop the 8.3 rows but
#     leaves `supported` untouched — same scenario, opposite
#     direction. Caught here.
#   * Auto-bump cron ran with a stale `supported` and the new
#     webtrees rows are missing a minor. Caught here.
#
# Schema-strict extraction of .supported:
#   * `select(type == "string" and (. | test("^[1-9][0-9]*\.[0-9]+$")))`
#     enforces the project's PHP-minor shape `<positive-digit>.<digit+>`
#     — drops nulls, numbers, arrays-of-arrays, empty strings,
#     whitespace (including invisible characters like zero-width
#     space U+200B), leading dots (`.3`), trailing dots (`8.`),
#     dot-only (`...`), patch-pinned (`8.3.1`), and any non-digit
#     character. Mirrors scripts/bump-nginx.py's `_MINOR_RE`
#     precedent; a hand-edited `.supported` that slips a malformed
#     value past this filter would propagate via the auto-bump cron
#     into every new versions.json row without any downstream layer
#     catching it.
#   * `unique` after the filter rejects accidental duplicates by
#     normalizing the input; the post-filter length check below
#     catches the symmetric case where the operator deliberately
#     listed a duplicate.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

jq_image="ghcr.io/jqlang/jq:latest"

docker run --rm \
    -v "$repo_root/dev:/d:ro" \
    -w /d \
    "$jq_image" \
    empty versions.json >/dev/null 2>&1 || {
    echo "::error::dev/versions.json is not parseable JSON" >&2
    exit 1
}

docker run --rm \
    -v "$repo_root/dev:/d:ro" \
    -w /d \
    "$jq_image" \
    empty php-versions.json >/dev/null 2>&1 || {
    echo "::error::dev/php-versions.json is not parseable JSON" >&2
    exit 1
}

# Expected: sorted unique `.supported` from php-versions.json.
# Actual (per webtrees-minor): sorted unique `.php` values for every
# row carrying that minor. Compare per-bucket; first drift fails loud
# with a `::error::` annotation naming the offending webtrees minor +
# the symmetric-difference set.
supported_raw=$(docker run --rm -v "$repo_root/dev:/d:ro" -w /d "$jq_image" \
    -r '(.supported // []) | length' php-versions.json) || {
    echo "::error::docker run for supported-php length-probe failed" >&2
    exit 1
}

supported_clean=$(docker run --rm -v "$repo_root/dev:/d:ro" -w /d "$jq_image" \
    -r '[(.supported // [])[] | select(type == "string" and (. | test("^[1-9][0-9]*\\.[0-9]+$")))] | unique' php-versions.json) || {
    echo "::error::docker run for supported-php clean-extract failed" >&2
    exit 1
}

supported_clean_count=$(printf '%s' "$supported_clean" | docker run --rm -i "$jq_image" -r length) || {
    echo "::error::docker run for supported-php length-count failed" >&2
    exit 1
}

if [ "$supported_raw" != "$supported_clean_count" ]; then
    echo "::error::dev/php-versions.json \`.supported\` contains duplicates, non-strings, empty values, whitespace-bearing entries, leading/trailing dots, patch-pinned (X.Y.Z), or values not matching the strict X.Y minor shape. Raw length: $supported_raw, post-filter length: $supported_clean_count." >&2
    exit 1
fi

supported=$(printf '%s' "$supported_clean" | docker run --rm -i "$jq_image" -r 'sort | join(",")') || {
    echo "::error::docker run for supported-php sort/join failed" >&2
    exit 1
}

[ -n "$supported" ] || {
    echo "::error::dev/php-versions.json \`.supported\` is missing, empty, or not an array" >&2
    exit 1
}

echo "  supported PHP minors: $supported"

webtrees_minors=$(docker run --rm -v "$repo_root/dev:/d:ro" -w /d "$jq_image" \
    -r '[.[].webtrees] | unique | .[]' versions.json) || {
    echo "::error::docker run for webtrees-minor extraction failed" >&2
    exit 1
}

for wt in $webtrees_minors; do
    actual=$(docker run --rm -v "$repo_root/dev:/d:ro" -w /d "$jq_image" \
        -r --arg wt "$wt" '[.[] | select(.webtrees == $wt) | .php] | sort | join(",")' versions.json) || {
        echo "::error::docker run for per-webtrees PHP extraction failed (wt=$wt)" >&2
        exit 1
    }
    if [ "$actual" != "$supported" ]; then
        echo "::error::dev/versions.json rows for webtrees $wt carry PHP '$actual' but dev/php-versions.json \`.supported\` is '$supported'. Add or remove rows so the two agree, or update php-versions.json if a minor was intentionally added/dropped." >&2
        exit 1
    fi
done

echo "  versions.json agrees with php-versions.json for $(printf '%s\n' "$webtrees_minors" | wc -l) webtrees minor(s)"
