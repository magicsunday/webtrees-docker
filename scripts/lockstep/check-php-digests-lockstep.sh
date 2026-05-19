#!/usr/bin/env bash
# Asserts dev/php_digests.lock carries exactly one entry per supported
# PHP minor declared in dev/php-versions.json `.supported`. Invoked by
# `make ci-php-digests-lockstep`.
#
# The .lock file is seeded by scripts/workflow/probe-php-digests.sh on
# every cron tick of check-php.yml. A hand-edit dropping a supported
# minor's line, or a stale line for a minor that's been removed from
# `.supported`, would survive every other lockstep check — probe-php-
# digests.sh repopulates missing entries silently on its next run and
# never prunes orphans. This guard pins the symmetric-difference
# invariant locally so drift fails loud in CI rather than at probe
# time.
#
# Line format the .lock carries:
#   <minor>=sha256:<64-hex>
# where <minor> matches the strict X.Y shape (`^[1-9][0-9]*\.[0-9]+$`)
# also enforced by check-php-versions.sh.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

# shellcheck source=scripts/lib/images.env
source "$(dirname "$0")/../lib/images.env"

lock_file="dev/php_digests.lock"
[ -f "$lock_file" ] || {
    echo "::error::$lock_file is missing" >&2
    exit 1
}

ci_run_jq "$repo_root" empty php-versions.json >/dev/null 2>&1 || {
    echo "::error::dev/php-versions.json is not parseable JSON" >&2
    exit 1
}

# Line-shape sanity: every non-empty, non-comment line must match
# `<minor>=sha256:<64-hex>`. A malformed line surfaces here with the
# exact offending content rather than later via a confused consumer.
while IFS= read -r line; do
    case "$line" in
        ''|'#'*) continue ;;
    esac
    if [[ ! "$line" =~ ^[1-9][0-9]*\.[0-9]+=sha256:[0-9a-f]{64}$ ]]; then
        echo "::error::$lock_file contains malformed line: '$line' (expected <minor>=sha256:<64-hex>)" >&2
        exit 1
    fi
done < "$lock_file"

supported=$(ci_run_jq "$repo_root" \
    -r '[.supported // []] | flatten | sort | join(",")' php-versions.json) || {
    echo "::error::docker run for .supported extraction failed" >&2
    exit 1
}

lock_keys=$(awk -F= '/^[^#]/ && NF >= 2 { print $1 }' "$lock_file" | sort -u | paste -sd, -)

if [ "$supported" != "$lock_keys" ]; then
    echo "::error::dev/php_digests.lock key set drift: have '$lock_keys', expected '$supported' (from dev/php-versions.json .supported)" >&2
    exit 1
fi

echo "  php_digests.lock keys: $lock_keys (matches dev/php-versions.json .supported)"
