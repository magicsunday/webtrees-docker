#!/usr/bin/env bash
# Asserts dev/versions.json has exactly one row per supported PHP minor
# per webtrees minor. Invoked by `make ci-php-versions-lockstep`.
#
# The single source of truth for supported PHP minors is
# dev/php-versions.json `.supported`, modelled as a per-webtrees-minor
# map (`{"2.1": ["8.3","8.4"], "2.2": ["8.3","8.4","8.5"]}`) because
# upstream webtrees branches drop or add PHP support independently —
# 2.1.x lost 8.5 support that 2.2.x carries forward. A single flat
# `.supported` list would force the catalog to ship rows that upstream
# composer cannot resolve (transitive plugin pins block the build).
#
# For every unique webtrees minor in `dev/versions.json`, the set of
# `.php` values across that minor's rows MUST equal
# `.supported[<wt-minor>]` exactly (no missing minor, no extra).
#
# Drift modes this catches:
#   * Operator bumps `.supported["2.2"]` from [8.3,8.4,8.5] to
#     [8.4,8.5,8.6] but forgets to refresh the 2.2.x rows in
#     versions.json — the auto-bump cron would then ship inconsistent
#     matrices on the next webtrees release. Caught here.
#   * Operator hand-edits versions.json to drop the 8.3 rows of a
#     webtrees minor but leaves the matching `.supported[<wt-minor>]`
#     untouched — same scenario, opposite direction. Caught here.
#   * Auto-bump cron ran with a stale `.supported` map and the new
#     webtrees rows are missing a minor. Caught here.
#   * versions.json carries rows for a webtrees minor that has no
#     entry in `.supported` (e.g. a new 2.3.x branch landed in the
#     catalog before php-versions.json grew its key). Caught here.
#   * `.supported` has an entry for a webtrees minor that no longer
#     appears in versions.json (e.g. 2.0.x was retired but its key
#     was forgotten). Caught here.
#
# Schema-shape validation lives in scripts/lib/php-versions-lib.sh
# (`ci_validate_php_supported_shape`) so all four `.supported`
# consumers gate on the same invariants.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

# shellcheck source=scripts/lib/images.env
source "$(dirname "$0")/../lib/images.env"
# shellcheck source=scripts/lib/php-versions-lib.sh
source "$(dirname "$0")/../lib/php-versions-lib.sh"

ci_run_jq "$repo_root" empty versions.json >/dev/null 2>&1 || {
    echo "::error::dev/versions.json is not parseable JSON" >&2
    exit 1
}

ci_run_jq "$repo_root" empty php-versions.json >/dev/null 2>&1 || {
    echo "::error::dev/php-versions.json is not parseable JSON" >&2
    exit 1
}

ci_validate_php_supported_shape "$repo_root"

# Diagnostic: show the per-minor expectations the rest of the run
# will enforce.
expectations=$(ci_run_jq "$repo_root" \
    -r '.supported | to_entries | map("\(.key)=[\(.value | sort | join(","))]") | join(" ")' php-versions.json) || {
    echo "::error::docker run for .supported expectation-render failed" >&2
    exit 1
}
echo "  supported PHP minors per webtrees minor: $expectations"

# Webtrees minors used in versions.json — derived by stripping the
# patch from `.webtrees` (e.g. "2.1.27" -> "2.1") so the lookup
# against `.supported` keys is direct. The capture regex anchors at
# start-of-string and the trailing `.[0-9]+` requires the patch to
# be present, so "2.1" alone (no patch) yields no minor — the
# downstream loop then correctly fails closed on the missing key.
webtrees_minors=$(ci_run_jq "$repo_root" \
    -r '[.[] | (.webtrees | capture("^(?<m>[1-9][0-9]*\\.[0-9]+)") | .m)] | unique | .[]' versions.json) || {
    echo "::error::docker run for webtrees-minor extraction failed" >&2
    exit 1
}

# Supported keys not present in versions.json — `.supported` has a
# leftover entry for a retired webtrees branch. The cron's fan-out
# would still emit rows for it on the next bump, materialising image
# tags for a branch the maintainer considers dead.
present_csv=$(printf '%s\n' "$webtrees_minors" | paste -sd, -)
# shellcheck disable=SC2016
# `$present` inside the single-quoted jq filter is the jq variable
# bound via `--arg`, not a bash expansion. Splitting the CSV inside
# jq keeps the orphan-key set arithmetic in a single jq pass without
# a host-jq stdin sub-call.
orphans=$(ci_run_jq "$repo_root" \
    --arg present "$present_csv" \
    -r '.supported | keys - ($present | split(",")) | join(",")' \
    php-versions.json) || {
    echo "::error::docker run for .supported orphan-key probe failed" >&2
    exit 1
}
if [ -n "$orphans" ]; then
    echo "::error::dev/php-versions.json \`.supported\` has key(s) but dev/versions.json has no row for that webtrees minor: $orphans. Either re-add a row or drop the orphan key(s)." >&2
    exit 1
fi

for wt in $webtrees_minors; do
    # shellcheck disable=SC2016
    # `$wt` inside the single-quoted jq filter is the jq variable
    # bound via `--arg`, not a bash expansion.
    has_key=$(ci_run_jq "$repo_root" \
        -r --arg wt "$wt" '.supported | has($wt)' php-versions.json) || {
        echo "::error::docker run for .supported[wt] presence-probe failed (wt=$wt)" >&2
        exit 1
    }
    if [ "$has_key" != "true" ]; then
        echo "::error::dev/versions.json carries rows for webtrees minor '$wt' but dev/php-versions.json \`.supported\` has no entry for it. Add \`.supported[\"$wt\"]\` listing the PHP minors that this webtrees branch supports." >&2
        exit 1
    fi

    # shellcheck disable=SC2016
    # `$wt` inside the single-quoted jq filter is the jq variable
    # bound via `--arg`, not a bash expansion.
    expected=$(ci_run_jq "$repo_root" \
        -r --arg wt "$wt" '.supported[$wt] | sort | join(",")' php-versions.json) || {
        echo "::error::docker run for .supported[wt] extraction failed (wt=$wt)" >&2
        exit 1
    }

    # shellcheck disable=SC2016
    # `$wt` inside the single-quoted jq filter is the jq variable
    # bound via `--arg`, not a bash expansion. The trailing `.`
    # appended to `$wt` is what prevents `startswith("2.1")` from
    # falsely claiming `"2.10.x"` rows for the `2.1` bucket.
    actual=$(ci_run_jq "$repo_root" \
        -r --arg wt "$wt" '[.[] | select(.webtrees | startswith($wt + ".")) | .php] | sort | join(",")' versions.json) || {
        echo "::error::docker run for per-webtrees PHP extraction failed (wt=$wt)" >&2
        exit 1
    }
    if [ "$actual" != "$expected" ]; then
        echo "::error::dev/versions.json rows for webtrees $wt carry PHP '$actual' but dev/php-versions.json \`.supported[\"$wt\"]\` is '$expected'. Add or remove rows so the two agree, or update php-versions.json if a minor was intentionally added/dropped." >&2
        exit 1
    fi
done

echo "  versions.json agrees with php-versions.json for $(printf '%s\n' "$webtrees_minors" | wc -l) webtrees minor(s)"
