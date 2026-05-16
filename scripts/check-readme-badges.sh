#!/usr/bin/env bash
# Asserts the static README badges encode every unique webtrees / PHP
# value from `dev/versions.json`. Invoked by `make ci-readme-badge-
# lockstep`.
#
# The README badges are static `img.shields.io/badge/<label>-<msg>-<color>`
# URLs spelling out every unique version `|`-separated (e.g.
# `2.1.27%7C2.2.6` for webtrees, `8.3%7C8.4%7C8.5` for PHP). Static
# rather than shields.io `dynamic/json` because that endpoint cannot
# dedupe + sort an array of values — we'd otherwise render duplicates.
#
# Invariant: every unique `.webtrees` / `.php` value in versions.json
# must appear in the matching badge URL. Bumping versions.json without
# touching the README fails this check, mirroring the alpine lockstep
# discipline.
#
# `sort_by(split(".") | map(tonumber? // 0))` produces NATURAL numeric
# ordering so a future `8.10` lands AFTER `8.5` (lexical sort would
# place `8.10` before `8.3`). The `tonumber? // 0` fallback keeps
# pre-release tags (`2.3.0-beta.1` etc.) sortable without crashing jq —
# they bucket at "0" for the non-numeric segment. Caveat: a release
# `2.3.0` and its pre-release `2.3.0-beta.1` bucket to the same key;
# jq's sort is stable, so their badge-URL order matches their order in
# versions.json. The README author must encode the pair in the same
# order the renderer writes; the grep is a fixed-string check, not a
# set-equality check. Avoid coexisting release+pre-release in
# versions.json if possible.
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

jq_image="ghcr.io/jqlang/jq:latest"

docker run --rm \
    -v "$repo_root/dev:/d:ro" \
    -w /d \
    "$jq_image" \
    empty versions.json >/dev/null 2>&1 || {
    echo "::error::dev/versions.json is not parseable JSON" >&2
    exit 1
}

# `|| exit 1` on each docker substitution: an empty result would
# silently produce `webtrees--blue` and grep would fail with a
# misleading "does not encode ''" — fail loud on the actual cause.
expected_wt=$(docker run --rm -v "$repo_root/dev:/d:ro" -w /d "$jq_image" \
    -r '[.[].webtrees | select(type == "string" and (. | test("\\S")))] | unique | sort_by(split(".") | map(tonumber? // 0)) | join("|")' versions.json) || {
    echo "::error::docker run for webtrees pin extraction failed" >&2
    exit 1
}
expected_php=$(docker run --rm -v "$repo_root/dev:/d:ro" -w /d "$jq_image" \
    -r '[.[].php | select(type == "string" and (. | test("\\S")))] | unique | sort_by(split(".") | map(tonumber? // 0)) | join("|")' versions.json) || {
    echo "::error::docker run for php pin extraction failed" >&2
    exit 1
}

[ -n "$expected_wt" ] && [ -n "$expected_php" ] || {
    echo "::error::empty pin extraction (webtrees=$expected_wt php=$expected_php) — check dev/versions.json" >&2
    exit 1
}

echo "  expected webtrees: $expected_wt"
echo "  expected PHP:      $expected_php"

wt_encoded=$(printf '%s' "$expected_wt" | sed 's#|#%7C#g')
php_encoded=$(printf '%s' "$expected_php" | sed 's#|#%7C#g')

grep -qF "img.shields.io/badge/webtrees-$wt_encoded-blue" README.md || {
    echo "::error::README webtrees badge does not encode '$expected_wt' — bump the static badge URL alongside dev/versions.json." >&2
    exit 1
}
grep -qF "img.shields.io/badge/PHP-$php_encoded-787CB5" README.md || {
    echo "::error::README PHP badge does not encode '$expected_php' — bump the static badge URL alongside dev/versions.json." >&2
    exit 1
}
