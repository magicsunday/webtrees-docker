#!/usr/bin/env bash
# Asserts every local caller of the cron-docker-hub-poll.yml reusable
# workflow declares a top-level `permissions:` block granting at least the
# write scopes the reusable's jobs request.
#
# Why: a called reusable workflow's GITHUB_TOKEN is capped by the CALLER's
# top-level permissions — a job-level grant inside the reusable can only
# narrow that cap, never widen it. This repo's default workflow token is
# read-only, so a caller that omits the block (or under-grants it) makes
# the run fail at STARTUP: no job runs, no logs, and notify-on-failure
# never fires (so no tracking issue is filed either). This regressed once
# already when GH-140 consolidated the standalone pollers into the
# reusable and dropped their top-level permission blocks.
#
# Single source of truth: the reusable's job-level `permissions:` blocks.
# The required write set is their union; every caller must grant a
# superset. Add a write scope to a reusable job and this check fails every
# caller that has not mirrored it.
#
# Format assumption: block-form `permissions:` with one `key: write` per
# line. The inline `permissions: {}` / `permissions: write-all` forms are
# not parsed as per-key grants — an empty/all caller block surfaces as
# missing scopes (fails loud) rather than passing vacuously.
#
# Failure-path test in tests/test-lockstep.sh strips a caller's grant.

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

reusable=.github/workflows/cron-docker-hub-poll.yml
[ -f "$reusable" ] || {
    echo "::error::$reusable not found" >&2
    exit 1
}

# Emit one permission key per `<key>: write` line inside any block-form
# `permissions:` block in the given file, at any indent depth. A block
# runs from a `permissions:` line (nothing but whitespace after the colon)
# until the first non-blank line indented no deeper than the `permissions:`
# keyword. Output is sorted + de-duplicated so callers can `comm` against it.
perm_writes() {
    awk '
        function ind(s) { match(s, /^[ ]*/); return RLENGTH }
        /^[ ]*permissions:[ ]*$/ { in_perm = 1; base = ind($0); next }
        in_perm {
            if ($0 ~ /^[ ]*$/) { next }
            if (ind($0) <= base) { in_perm = 0; next }
            if ($0 ~ /:[ ]*write[ ]*$/) {
                key = $0
                sub(/^[ ]*/, "", key)
                sub(/:[ ]*write[ ]*$/, "", key)
                print key
            }
        }
    ' "$1" | sort -u
}

required=$(perm_writes "$reusable")
[ -n "$required" ] || {
    echo "::error::no job-level 'write' permission found in $reusable — parser drift? (refusing to pass vacuously)" >&2
    exit 1
}

# Local callers: workflows carrying `uses: ./.github/workflows/cron-docker-hub-poll.yml`.
callers=$(grep -rlE 'uses:[[:space:]]*\./\.github/workflows/cron-docker-hub-poll\.yml' .github/workflows/ || true)
[ -n "$callers" ] || {
    echo "::error::no caller of $reusable found — parser drift? (refusing to pass vacuously)" >&2
    exit 1
}

rc=0
n=0
for caller in $callers; do
    n=$((n + 1))
    have=$(perm_writes "$caller")
    missing=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$have"))
    if [ -n "$missing" ]; then
        echo "::error::$caller is missing top-level permissions required by ${reusable##*/}:" >&2
        # Word-split is intentional: one missing scope per diagnostic line.
        # shellcheck disable=SC2086
        printf '  - %s: write\n' $missing >&2
        rc=1
    fi
done

if [ "$rc" -eq 0 ]; then
    echo "  $n cron-poll caller(s) grant the required write scopes: $(printf '%s' "$required" | tr '\n' ' ')"
fi
exit "$rc"
