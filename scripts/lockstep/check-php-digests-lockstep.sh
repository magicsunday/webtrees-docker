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

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
# shellcheck source=scripts/lib/php-versions-lib.sh
source "$(dirname "$0")/../lib/php-versions-lib.sh"
lockstep_init "$@"

lock_file="dev/php_digests.lock"
[ -f "$lock_file" ] || {
    echo "::error::$lock_file is missing" >&2
    exit 1
}

assert_jq_parseable "$repo_root" php-versions.json

# Schema-shape gate before the union extraction so a pre-migration
# flat-array `.supported` (or any other malformed shape) fails with a
# clear schema diagnostic rather than jq's opaque 'Cannot iterate
# over string'. Mirrors the gate at the top of check-php-versions.sh
# so individual-target invocations of this script (without the
# umbrella `make ci-test`) still produce actionable errors.
ci_validate_php_supported_shape "$repo_root"

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

# `.supported` is a per-webtrees-minor map (see check-php-versions.sh
# for the schema and rationale). The digest .lock pins images by PHP
# minor regardless of which webtrees branch consumes them, so the
# expected key set is the UNION of every value array across keys —
# routed through the shared helper so a future schema migration
# touches one place, not three.
supported=$(ci_php_supported_union "$repo_root") || {
    echo "::error::ci_php_supported_union failed" >&2
    exit 1
}

lock_keys=$(awk -F= '/^[^#]/ && NF >= 2 { print $1 }' "$lock_file" | sort -u | paste -sd, -)

if [ "$supported" != "$lock_keys" ]; then
    echo "::error::dev/php_digests.lock key set drift: have '$lock_keys', expected '$supported' (from dev/php-versions.json .supported)" >&2
    exit 1
fi

echo "  php_digests.lock keys: $lock_keys (matches dev/php-versions.json .supported)"
