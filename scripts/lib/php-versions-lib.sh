# =============================================================================
# Shared helpers for the dev/php-versions.json per-webtrees-minor map.
# =============================================================================
#
# `.supported` in dev/php-versions.json is a map keyed by webtrees minor:
#
#   {"supported": {"2.1": ["8.3","8.4"], "2.2": ["8.3","8.4","8.5"]}}
#
# Branches that drop PHP support (e.g. webtrees 2.1.x not supporting
# PHP 8.5) keep an honest catalog. Three lockstep checks plus the
# auto-bump cron all walk this map; the helpers below remove the
# regex / union-extraction / shape-gate duplication that the
# migration would otherwise scatter across the consumers.
#
# DEPENDENCY: two of the three helpers (ci_validate_php_supported_shape
# and ci_php_supported_union) call into ci_run_jq from images.env, so
# consumers MUST source images.env first.
#
# Usage in a script:
#   # shellcheck source=scripts/lib/images.env
#   source "$(dirname "$0")/../lib/images.env"
#   # shellcheck source=scripts/lib/php-versions-lib.sh
#   source "$(dirname "$0")/../lib/php-versions-lib.sh"
#   ci_validate_php_supported_shape "$repo_root"
#   union=$(ci_php_supported_union "$repo_root")

# Idempotent source guard: a future caller may end up sourcing this
# lib transitively (e.g. via a `ci_bootstrap` wrapper that consolidates
# the two-line preamble above) AND directly. Re-evaluating `readonly`
# in the same shell on the next source would exit 1 under `set -e`
# with `readonly variable`. Bailing out early on a second source keeps
# the contract idempotent.
[ -n "${CI_MINOR_RE:-}" ] && return 0 2>/dev/null || true

# Strict X.Y minor shape used by every key and every value across the
# whole map. Defined once here so a future tightening (e.g. forbid
# double-digit minors) cascades to every `.supported` consumer in one
# edit. The leading `[1-9]` rejects leading-zero majors; the trailing
# `[0-9]+` requires at least one digit after the dot, rejecting `8.`.
readonly CI_MINOR_RE='^[1-9][0-9]*\.[0-9]+$'

# jq filter that returns the UNION of every PHP-minor across every
# webtrees-minor in `.supported`. Used by consumers that care about
# the PHP-minor membership independent of which branch consumes it
# (e.g. .env.dist's single PHP_VERSION pin, dev/php_digests.lock's
# per-PHP-minor entries).
readonly CI_PHP_SUPPORTED_UNION_JQ='[(.supported // {}) | to_entries[] | .value[]] | unique'

# Strips the patch suffix from a fully-qualified webtrees patch
# version (e.g. "2.1.27" -> "2.1"). The sed expression rewrites only
# when the input matches `^X.Y...`; non-matching input flows through
# unchanged (sed's default behaviour). The downstream consumer is
# expected to validate the result against CI_MINOR_RE or the
# `.supported | has($wt)` lookup so a non-conforming input surfaces
# as a key-not-found error rather than a silent corruption.
ci_wt_minor_strip_patch() {
    printf '%s' "$1" | sed -E "s/^([1-9][0-9]*\\.[0-9]+).*/\\1/"
}

# Validates the shape of dev/php-versions.json `.supported`:
#   * `.supported` is a non-null object (top-level type gate)
#   * every key matches CI_MINOR_RE
#   * every value is a non-empty array of unique strings matching
#     CI_MINOR_RE
# Emits `::error::` annotations and exits 1 on the first violation.
# Returns 0 on a clean shape.
#
# Callers must have already sourced scripts/lib/images.env so the
# `ci_run_jq` helper is in scope.
ci_validate_php_supported_shape() {
    local repo_root=$1

    local supported_type
    supported_type=$(ci_run_jq "$repo_root" \
        -r '.supported | type' php-versions.json) || {
        echo "::error::docker run for .supported type-probe failed" >&2
        exit 1
    }
    if [ "$supported_type" != "object" ]; then
        echo "::error::dev/php-versions.json \`.supported\` must be an object mapping webtrees-minor (e.g. \"2.1\") to a list of PHP minors; got type '$supported_type'" >&2
        exit 1
    fi

    local bad_keys
    # shellcheck disable=SC2016
    # `$re` inside the single-quoted jq filter is the jq variable
    # bound via `--arg`, not a bash expansion.
    bad_keys=$(ci_run_jq "$repo_root" \
        -r --arg re "$CI_MINOR_RE" \
        '[.supported | keys[] | select(test($re) | not)] | join(",")' \
        php-versions.json) || {
        echo "::error::docker run for .supported key-shape probe failed" >&2
        exit 1
    }
    if [ -n "$bad_keys" ]; then
        echo "::error::dev/php-versions.json \`.supported\` has key(s) not matching the strict webtrees-minor X.Y shape: $bad_keys" >&2
        exit 1
    fi

    local bad_values
    # shellcheck disable=SC2016
    # `$e`, `$re` inside the single-quoted jq filter are jq variables
    # (locally bound via `. as $e`, externally via `--arg re`), not
    # bash expansions.
    bad_values=$(ci_run_jq "$repo_root" \
        -r --arg re "$CI_MINOR_RE" '
            [
                .supported
                | to_entries[]
                | . as $e
                | if ($e.value | type) != "array" then
                    "\($e.key): value is not an array"
                  elif ($e.value | length) == 0 then
                    "\($e.key): value is empty"
                  elif ($e.value | unique | length) != ($e.value | length) then
                    "\($e.key): value has duplicates"
                  elif any($e.value[]; (type != "string") or (test($re) | not)) then
                    "\($e.key): value has entry not matching strict PHP-minor X.Y shape"
                  else
                    empty
                  end
            ] | join("; ")
        ' php-versions.json) || {
        echo "::error::docker run for .supported value-shape probe failed" >&2
        exit 1
    }
    if [ -n "$bad_values" ]; then
        echo "::error::dev/php-versions.json \`.supported\` value(s) malformed: $bad_values" >&2
        exit 1
    fi
}

# Emits the union of every PHP-minor across every webtrees-minor in
# `.supported`, sorted and comma-joined on stdout. Used as input for
# membership checks against single-PHP pins (.env.dist) and per-PHP-
# minor inventories (dev/php_digests.lock).
#
# Callers MUST source images.env first.
ci_php_supported_union() {
    local repo_root=$1
    ci_run_jq "$repo_root" \
        -r "$CI_PHP_SUPPORTED_UNION_JQ | sort | join(\",\")" \
        php-versions.json
}
