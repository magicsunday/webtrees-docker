#!/usr/bin/env bash
# Asserts every `cache-to: type=gha` entry in build.yml carries
# `ignore-error=true` (GH-187).
#
# A GitHub Actions cache backend 5xx on EXPORT must degrade to a cache
# miss, not fail an otherwise-green build. `ignore-error=true` is the
# only BuildKit knob that makes the export best-effort; it is a no-op on
# the happy path. During the 2026-06-08 GHA incident a backend 504 broke
# every build cell, and the images only published once the backend
# recovered and the jobs were re-run — the regression this guard makes
# impossible to reintroduce by dropping the flag from one of the four
# build steps.
#
# Scope: build.yml only — the one workflow that runs `docker
# build-push-action` with `type=gha` cache. The import side
# (`cache-from`) has no equivalent flag (moby/buildkit#2836, open) and
# is out of scope; this guard is export-only by design.
#
# Format assumption: the YAML key form `cache-to: type=gha,...`,
# 4-space-or-deeper indented. The leading-whitespace anchor excludes the
# documentation comment in build.yml that mentions `cache-to: type=gha`
# in prose. Attribute order is free — the check is a substring test for
# `ignore-error=true`, so `type=gha,mode=max,...,ignore-error=true` and
# `type=gha,scope=...,mode=max,ignore-error=true` both pass.
#
# Failure-path test in tests/test-lockstep.sh strips the flag from one
# entry and asserts this script exits non-zero.

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

file=.github/workflows/build.yml
[ -f "$file" ] || {
    echo "::error::$file not found" >&2
    exit 1
}

# Real `cache-to:` keys only: indented key form, not the prose mention
# in the canonical doc comment (which has `# ` + backtick before the
# token, so it never matches the leading-whitespace-then-key anchor).
cache_to_lines=$(grep -nE '^[[:space:]]+cache-to:[[:space:]]*type=gha' "$file" || true)

[ -n "$cache_to_lines" ] || {
    echo "::error::no 'cache-to: type=gha' entries found in $file — the parser or the workflow changed shape; update $0" >&2
    exit 1
}

rc=0
count=0
while IFS= read -r line; do
    count=$((count + 1))
    case "$line" in
        *ignore-error=true*) ;;
        *)
            if [ "$rc" -eq 0 ]; then
                echo "::error::build.yml has 'cache-to: type=gha' entries missing 'ignore-error=true' (a cache-export 5xx would fail an otherwise-green build — GH-187):" >&2
            fi
            # Strip the build.yml content after the line number for a
            # compact, actionable diagnostic.
            echo "  ${file}:${line%%:*}" >&2
            rc=1
            ;;
    esac
done <<< "$cache_to_lines"

if [ "$rc" -eq 0 ]; then
    echo "  all $count 'cache-to: type=gha' entries carry ignore-error=true"
fi
exit "$rc"
