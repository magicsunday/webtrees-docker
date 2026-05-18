#!/usr/bin/env bash
# Asserts the static README badges encode every unique webtrees / PHP
# value from `dev/versions.json`. Invoked by `make ci-readme-badge-
# lockstep`.
#
# The README badges are static `img.shields.io/badge/<label>-<msg>-<color>`
# URLs spelling out every unique version `|`-separated (URL-encoded as
# `%7C`). Static rather than shields.io `dynamic/json` because that
# endpoint cannot dedupe + sort an array of values — we'd otherwise
# render duplicates.
#
# Invariant: the SET of `|`-separated values in the badge URL must
# equal the SET of unique `.webtrees` / `.php` values in versions.json
# exactly — no missing value, no extra value. Order is not asserted;
# the comparison is set-equality. The check-versions.yml auto-bump
# workflow runs scripts/rewrite-readme-badges.py in the same step
# that edits dev/versions.json so both files land in a single
# atomic commit, keeping this lockstep green on every PR.
#
# `select(type == "string" and (. | test("\\S")))` drops every
# schema-bad shape BEFORE `split(.)` runs: nulls, empty strings,
# whitespace-only, AND non-string types (integer, array, object).
# Without this, a malformed versions.json would crash jq with `split
# input must be a string` and the operator would see the generic
# `docker run failed` instead of an actionable `empty pin extraction`
# error.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

# Fail loud if README.md is missing entirely. Without this guard, the
# downstream `grep ... README.md` inside extract_msgs would fail with
# `No such file or directory`, the `|| true` would swallow exit 2,
# and the empty-result branch would emit a misleading `no badge URL
# found` annotation. Surface the actual cause first.
[ -f README.md ] || {
    echo "::error::README.md not found at $repo_root" >&2
    exit 1
}

# shellcheck source=scripts/lib/images.env
source "$(dirname "$0")/../lib/images.env"

ci_run_jq "$repo_root" empty versions.json >/dev/null 2>&1 || {
    echo "::error::dev/versions.json is not parseable JSON" >&2
    exit 1
}

# Expected sets — sorted-unique stripped strings from versions.json.
# The `gsub` mirrors `_extract_unique`'s `.strip()` in the Python
# rewriter so a hand-edited `"8.3 "` (trailing space) does not produce
# a divergent expected set vs. the rewriter's badge URL. The `select`
# already drops whitespace-only values; the `gsub` then strips the
# surviving values so the SET comparison sees the same canonical form
# the rewriter wrote to README.
expected_wt=$(ci_run_jq "$repo_root" \
    -r '[.[].webtrees | select(type == "string" and (. | test("\\S"))) | gsub("^\\s+|\\s+$"; "")] | unique | .[]' versions.json) || {
    echo "::error::docker run for webtrees pin extraction failed" >&2
    exit 1
}
expected_php=$(ci_run_jq "$repo_root" \
    -r '[.[].php | select(type == "string" and (. | test("\\S"))) | gsub("^\\s+|\\s+$"; "")] | unique | .[]' versions.json) || {
    echo "::error::docker run for php pin extraction failed" >&2
    exit 1
}

[ -n "$expected_wt" ] && [ -n "$expected_php" ] || {
    echo "::error::empty pin extraction (webtrees=$expected_wt php=$expected_php) — check dev/versions.json" >&2
    exit 1
}

echo "  expected webtrees: $(echo "$expected_wt" | tr '\n' ' ')"
echo "  expected PHP:      $(echo "$expected_php" | tr '\n' ' ')"

# Extract the actual badge message fields from README.md. The badge
# URL shape is `img.shields.io/badge/<label>-<msg>-<color>`; the
# message field is the URL-encoded `|`-separated value list. sed
# captures the message between `webtrees-` (or `PHP-`) and the
# trailing `-blue` / `-787CB5` color marker, decodes `%7C` back to
# `|`, then splits on `|` so the bash sort can compare set-equality.
#
# Validates EVERY matching badge URL, not just the first: the rewriter
# uses `re.subn` (replaces all occurrences), so the checker must scan
# all badges too. Each match feeds into the same union set; if a
# second context-specific badge (docs example / screenshot caption /
# archived release reference) carries a value not present in
# dev/versions.json, the lockstep must fail loud rather than silently
# accepting whatever the first badge happened to encode.
extract_msgs() {
    # Args: label color
    # The message-field character class `[A-Za-z0-9.%_-]` matches
    # what the current catalog actually produces (alphanumerics + `.`
    # `%` `_` `-` — `%` covers `%7C` separator + future `%xx`-encoded
    # values; literal `-` must remain last in the class to avoid
    # range interpretation) and excludes everything else, so the
    # regex stops at the FIRST `-${color}` boundary rather than
    # greedily eating across markdown wrappers `)] [![next-badge-
    # ...-${color}` on the same physical README line. Without this,
    # two same-color badges on one line would collapse into a single
    # match whose message field is junk.
    #
    # SemVer build-metadata characters (`+`, `~`) are NOT in this
    # class because shields.io renders literal `+` as a space in
    # static badge URLs (so `webtrees-2.3.0+build.1-blue` would
    # display as `2.3.0 build.1`) — if a future catalog ever needed
    # such values, the rewriter would have to %-encode them (`%2B`),
    # which the current `%` member already covers without widening
    # the class.
    # `grep || true`: a README with zero matching badge URLs is a real
    # failure mode (caught by the `[ -z "$actual_..._msgs" ]` guard
    # below with a dedicated `::error::` annotation), but under `set
    # -euo pipefail` an unguarded `grep` exit-1 would abort the script
    # in the `$(...)` capture before the guard can fire.
    local label=$1
    local color=$2
    {
        grep -oE "img\.shields\.io/badge/${label}-[A-Za-z0-9.%_-]+-${color}" README.md \
            || true
    } | sed -E "s|^img\.shields\.io/badge/${label}-(.*)-${color}\$|\1|"
}

actual_wt_msgs=$(extract_msgs webtrees blue)
actual_php_msgs=$(extract_msgs PHP 787CB5)

if [ -z "$actual_wt_msgs" ]; then
    echo "::error::no img.shields.io/badge/webtrees-...-blue URL found in README.md" >&2
    exit 1
fi
if [ -z "$actual_php_msgs" ]; then
    echo "::error::no img.shields.io/badge/PHP-...-787CB5 URL found in README.md" >&2
    exit 1
fi

# Decode `%7C` → `|`, split on `|`. Reject duplicate entries WITHIN a
# single badge URL before the set comparison: `sort -u` alone would
# collapse `2.1.27%7C2.2.6%7C2.1.27` (a hand-edit / merge-conflict
# artefact) into the same set as `2.1.27%7C2.2.6`, hiding a malformed
# badge that renders `2.1.27 | 2.2.6 | 2.1.27` to readers. The
# duplicate check runs per-line so multiple SEPARATE badge URLs may
# share values legitimately.
check_no_dupes() {
    local label=$1 msgs=$2
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local raw_count uniq_count
        raw_count=$(printf '%s\n' "$line" | sed 's|%7C|\n|g' | grep -c '')
        uniq_count=$(printf '%s\n' "$line" | sed 's|%7C|\n|g' | sort -u | grep -c '')
        if [ "$raw_count" != "$uniq_count" ]; then
            dupes=$(printf '%s\n' "$line" | sed 's|%7C|\n|g' | sort | uniq -d | tr '\n' ' ')
            echo "::error::README ${label} badge URL contains duplicate values: '${dupes% }' — run scripts/rewrite-readme-badges.py to regenerate." >&2
            return 1
        fi
    done <<< "$msgs"
}
check_no_dupes webtrees "$actual_wt_msgs"
check_no_dupes PHP "$actual_php_msgs"

# Decode `%7C` → `|`, split on `|`, sort uniquely across ALL badges.
# The README badges are allowed to render in any order; the lockstep
# only enforces the set membership across the union of every matching
# badge.
actual_wt=$(printf '%s\n' "$actual_wt_msgs" | sed 's|%7C|\n|g' | sort -u)
actual_php=$(printf '%s\n' "$actual_php_msgs" | sed 's|%7C|\n|g' | sort -u)

expected_wt_sorted=$(printf '%s\n' "$expected_wt" | sort -u)
expected_php_sorted=$(printf '%s\n' "$expected_php" | sort -u)

if [ "$actual_wt" != "$expected_wt_sorted" ]; then
    missing=$(comm -23 <(echo "$expected_wt_sorted") <(echo "$actual_wt") | tr '\n' ' ')
    extra=$(comm -13 <(echo "$expected_wt_sorted") <(echo "$actual_wt") | tr '\n' ' ')
    echo "::error::README webtrees badge does not encode the same set as dev/versions.json — missing: '${missing% }', extra: '${extra% }'. Run scripts/rewrite-readme-badges.py to regenerate." >&2
    exit 1
fi
if [ "$actual_php" != "$expected_php_sorted" ]; then
    missing=$(comm -23 <(echo "$expected_php_sorted") <(echo "$actual_php") | tr '\n' ' ')
    extra=$(comm -13 <(echo "$expected_php_sorted") <(echo "$actual_php") | tr '\n' ' ')
    echo "::error::README PHP badge does not encode the same set as dev/versions.json — missing: '${missing% }', extra: '${extra% }'. Run scripts/rewrite-readme-badges.py to regenerate." >&2
    exit 1
fi
