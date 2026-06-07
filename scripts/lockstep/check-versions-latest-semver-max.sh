#!/usr/bin/env bash
# Asserts the `"latest"` tag in dev/versions.json sits on the row that
# carries the semver-max `webtrees` value. Invoked by
# `make ci-versions-latest-semver-max-lockstep`.
#
# The build workflow publishes whatever entry holds `"latest"` in its
# `tags[]` as `ghcr.io/magicsunday/webtrees-php:latest`. A PR that
# moves the marker onto an older (or known-vulnerable) row would
# retag the older image as `:latest` on the next dispatch with no
# friction beyond human PR review. This guard re-computes the
# expected row from the data itself and fails loud if the marker is
# anywhere other than the semver-max-webtrees row.
#
# Sibling series tags (`2.2`, `2.1`) are NOT asserted here — they
# legitimately track the highest patch within their own major.minor,
# which is a different invariant. Only the catch-all `"latest"` is
# guarded.

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

assert_jq_parseable "$repo_root" versions.json

# Highest webtrees version by major.minor.patch — sort -V handles
# numeric-aware comparison the same way semver does for `X.Y.Z` shapes.
semver_max=$(ci_run_jq "$repo_root" \
    -r '[.[].webtrees] | unique | .[]' versions.json | sort -V | tail -n1)

[ -n "$semver_max" ] || {
    echo "::error::dev/versions.json carries no webtrees rows" >&2
    exit 1
}

# Expect: exactly one row carries `"latest"`, and its webtrees value
# equals $semver_max. Count rows first (a `unique` collapse on the
# webtrees field alone would let two rows with the same webtrees both
# carrying `latest` slip through; the build workflow would then publish
# `:latest` from two cells racing each other).
latest_count=$(ci_run_jq "$repo_root" \
    -r '[.[] | select(.tags | any(. == "latest"))] | length' versions.json) || {
    echo "::error::docker run for 'latest'-row count failed" >&2
    exit 1
}

if [ "$latest_count" -eq 0 ]; then
    echo "::error::dev/versions.json carries no row with the 'latest' tag (expected on webtrees $semver_max)" >&2
    exit 1
fi

if [ "$latest_count" -gt 1 ]; then
    echo "::error::dev/versions.json carries $latest_count rows with the 'latest' tag (must be exactly one, on webtrees $semver_max)" >&2
    exit 1
fi

latest_webtrees=$(ci_run_jq "$repo_root" \
    -r 'first(.[] | select(.tags | any(. == "latest")) | .webtrees)' versions.json)

if [ "$latest_webtrees" != "$semver_max" ]; then
    echo "::error::dev/versions.json 'latest' tag is on webtrees '$latest_webtrees' but the semver-max webtrees is '$semver_max'" >&2
    exit 1
fi

echo "  versions.json 'latest' tag: webtrees $semver_max (semver-max)"
