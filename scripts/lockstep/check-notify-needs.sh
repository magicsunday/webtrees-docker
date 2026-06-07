#!/usr/bin/env bash
# Asserts build.yml's `notify-on-failure` job `needs:` every other
# top-level job (issue #154). GitHub Actions has no glob for `needs:`,
# so a build job added without a matching entry in the hand-maintained
# list silently loses failure notification — the exact drift the inline
# comment on that `needs:` line warns about. This makes the coverage
# mandatory instead of review-enforced.
#
# Scope: build.yml only. It is the one workflow with a fan-out job graph
# where the notifier must wait on many siblings; the check-*.yml
# notifiers `needs: [check]` a single job and have nothing to drift
# against.
#
# Format assumption: the notify job's `needs:` is the inline-array form
# `needs: [a, b, c]`. A switch to the YAML block-list form would make
# the parser miss the list — it fails loud with a clear error rather
# than passing emptily, so the format change forces a parser update.
#
# Failure-path test in tests/test-lockstep.sh injects a bogus job.

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

file=.github/workflows/build.yml
[ -f "$file" ] || {
    echo "::error::$file not found" >&2
    exit 1
}

# Top-level job names: 4-space-indented `<name>:` keys after the `jobs:`
# line, up to the next column-0 line (jobs is the last top-level block).
all_jobs=$(awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^[^[:space:]]/ { in_jobs = 0 }
    in_jobs && /^    [a-zA-Z0-9_-]+:[[:space:]]*$/ {
        name = $1; sub(/:$/, "", name); print name
    }
' "$file")

# The notify job's inline `needs: [..]` line.
needs_line=$(awk '
    /^    notify-on-failure:[[:space:]]*$/ { in_notify = 1; next }
    in_notify && /^    [a-zA-Z0-9_-]+:[[:space:]]*$/ { in_notify = 0 }
    in_notify && /^        needs:[[:space:]]*\[/ { print; exit }
' "$file")

[ -n "$needs_line" ] || {
    echo "::error::could not find notify-on-failure inline 'needs: [..]' in $file" >&2
    exit 1
}

# [a, b, c] -> one name per line.
needs=$(printf '%s\n' "$needs_line" \
    | sed -E 's/^[[:space:]]*needs:[[:space:]]*\[//; s/].*$//; s/,/ /g' \
    | tr ' ' '\n' \
    | grep -v '^$' || true)

# Coverage target = every top-level job except notify-on-failure itself.
expected=$(printf '%s\n' "$all_jobs" | grep -v '^notify-on-failure$' | sort -u)
have=$(printf '%s\n' "$needs" | sort -u)

missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$have"))
extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$have"))

rc=0
if [ -n "$missing" ]; then
    echo "::error::build.yml notify-on-failure needs: is missing sibling jobs:" >&2
    # Word-split is intentional: one missing name per diagnostic line.
    # shellcheck disable=SC2086
    printf '  - %s\n' $missing >&2
    rc=1
fi
if [ -n "$extra" ]; then
    echo "::error::build.yml notify-on-failure needs: lists unknown jobs:" >&2
    # shellcheck disable=SC2086
    printf '  - %s\n' $extra >&2
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    echo "  notify-on-failure needs: covers all $(printf '%s\n' "$expected" | grep -c .) sibling jobs"
fi
exit "$rc"
