#!/usr/bin/env bash
# Polls Docker Hub's `library/<REPO_NAME>` tag listing, paginates
# through every `next` link, filters tags to a caller-supplied regex
# shape, optionally applies a stable-only post-filter, self-tests
# that the caller's `PINNED_MINOR` appears in the response, and
# prints the sorted-unique candidate minors to stdout.
#
# Shared across check-{alpine,mariadb,nginx,php}.yml — each workflow
# differs only by repo + filter + regex + (optional) stable-minor
# policy. Keeping the shared shell in a single script means shellcheck
# covers it, the failure-path tests under `tests/test-shared-scripts.sh`
# exercise it in isolation, and a future Docker Hub schema regression
# is fixed once across all four pollers.
#
# Required env vars:
#   REPO_NAME      Docker Hub repo under `library/` (e.g. `alpine`,
#                  `mariadb`, `nginx`, `php`).
#   NAME_FILTER    `name=` query passed to Docker Hub (server-side
#                  prefix filter, e.g. `3.` for Alpine, `alpine` for
#                  nginx -alpine variants, `-fpm-alpine` for PHP).
#   REGEX          ERE pattern the tag must match on the client side
#                  AFTER the API response (e.g. `^[0-9]+\.[0-9]+$`
#                  for `X.Y` minors). Anchored matches are highly
#                  recommended — an unanchored pattern would let
#                  patch-pinned variants slip through.
#   PINNED_MINOR   The minor currently pinned by the consumer
#                  (e.g. `3.23` for Alpine, `1.30` for nginx). The
#                  self-test asserts this value appears in the
#                  filtered + post-filtered listing so a green run
#                  cannot silently scan nothing.
#
# Optional env vars:
#   STRIP_SUFFIX   sed pattern stripped from each tag before
#                  comparison (e.g. `-alpine$` for nginx,
#                  `-fpm-alpine$` for PHP). Applied AFTER the regex
#                  filter so the anchored regex still pins the shape.
#   EVEN_MINORS_ONLY  Set to `1` to retain only even minors (X.0,
#                  X.2, X.4, …). Used by nginx, where odd minors are
#                  the mainline channel and project policy is to
#                  track only the stable even-minor branch.
#   ORDERING       Docker Hub `ordering=` query param. Defaults to
#                  `last_updated` (right choice when the result set
#                  could overflow page_size and an unfortunate sort
#                  order could push a new release off the first page).
#                  Override with `name` only when the result set is
#                  small enough that a single page suffices AND
#                  alphabetical stability is desired (PHP's sparse
#                  `X.Y-fpm-alpine` set is the precedent).
#   ALLOW_MISSING_PIN  Set to `1` to downgrade the pin self-test
#                  from a hard `::error::` exit-1 to a `::notice::`
#                  exit-0. Use this when the caller's `PINNED_MINOR`
#                  is allowed to LEAD upstream — e.g. the PHP scan
#                  derives it from `max(versions.json)` which can be
#                  seeded ahead of Docker Hub for a planned future
#                  release. Default (unset) keeps the strict
#                  fail-loud behaviour for callers whose pin is
#                  canonical (alpine/mariadb/nginx).
#
# Stdout: sorted-unique list of candidate minors, newline-separated.
# Exit codes:
#   0  Listing fetched and pinned minor validated.
#   1  Pinned minor not found in the filtered listing (regression
#      signal: page_size cap silently lowered, name filter regressed,
#      ordering quirk dropped the pin mid-pagination, or response
#      schema change).
# Transient Docker Hub failures (network / 5xx) emit a `::warning::`
# annotation and `exit 0` — the next cron iteration retries; a one-
# off blip should not fail the workflow.

set -euo pipefail

: "${REPO_NAME:?REPO_NAME env var is required}"
: "${NAME_FILTER:?NAME_FILTER env var is required}"
: "${REGEX:?REGEX env var is required}"
: "${PINNED_MINOR:?PINNED_MINOR env var is required}"

ordering="${ORDERING:-last_updated}"
# `ordering=last_updated` is the default and the right choice when
# the result set could overflow page_size: `ordering=name` sorts
# alphabetically (3.9.x lands after 3.20.x in lexical order) and
# could push a new release off the first 100 results unnoticed. The
# self-test below catches a silent drop either way.
url="https://hub.docker.com/v2/repositories/library/${REPO_NAME}/tags/?name=${NAME_FILTER}&page_size=100&ordering=${ordering}"
all_tags=""
while [ -n "$url" ] && [ "$url" != "null" ]; do
    # --max-time caps DNS + TCP + TLS + body per attempt so a Docker
    # Hub hang cannot stretch beyond the job's timeout-minutes
    # budget; --retry 3 still gives three goes within that cap.
    page=$(curl -sf --retry 3 --max-time 30 "$url") || {
        echo "::warning::Docker Hub tag fetch failed for library/${REPO_NAME}; skipping this iteration" >&2
        exit 0
    }
    # `?` + `// empty` keep jq tolerant of a future schema regression
    # where .results is null/missing — without them, `set -euo
    # pipefail` aborts the script mid-loop before the self-check can
    # fire the documented `::error::` annotation.
    all_tags+=$'\n'$(printf '%s' "$page" | jq -r '.results[]?.name // empty')
    url=$(printf '%s' "$page" | jq -r '.next // empty')
done

# Apply the caller's regex shape filter. `|| true` swallows grep's
# no-match exit so `set -e` + `pipefail` don't abort before the
# self-check can fire — `name=` filter regressions and schema
# changes route through here.
filtered=$(printf '%s' "$all_tags" \
    | { grep -E "$REGEX" || true; })

# Optional suffix strip (e.g. `-alpine` for nginx so the result
# compares directly against `.nginx_base`).
if [ -n "${STRIP_SUFFIX:-}" ]; then
    filtered=$(printf '%s\n' "$filtered" | sed "s/${STRIP_SUFFIX}//")
fi

# Optional even-minors policy filter (nginx stable channel).
if [ "${EVEN_MINORS_ONLY:-0}" = "1" ]; then
    filtered=$(printf '%s\n' "$filtered" | awk -F. '$2 % 2 == 0')
fi

available=$(printf '%s\n' "$filtered" | sort -uV)

# Self-test: the pinned minor MUST appear in the response. If it
# doesn't, the filter or pagination silently dropped it and a green
# run scanned nothing — fail loud rather than ship green-nothing.
# Exception: callers that derive PINNED_MINOR from a forward-looking
# source (e.g. PHP's `max(versions.json)` which is allowed to lead
# upstream during seed-a-future-version workflows) set
# ALLOW_MISSING_PIN=1 and accept a quiet `::notice::` instead. The
# downgrade requires `available` to be NON-empty so it cannot mask
# a filter-regression / empty-listing scenario as a benign
# leading-pin notice — an empty listing is always a strict failure
# because a forward-seeded pin is only legitimately missing from a
# listing that contains at least one other version.
# `grep <<<"$haystack"` (here-string) instead of `printf | grep`
# pipeline so `grep -q` short-circuiting on first match cannot
# SIGPIPE the upstream printf, which would propagate via pipefail
# and be silently swallowed by the `if !` shape. AGENTS.md
# documents this trap.
if ! grep -qFx "$PINNED_MINOR" <<<"$available"; then
    if [ "${ALLOW_MISSING_PIN:-0}" = "1" ] && [ -n "$available" ]; then
        echo "::notice::Pinned ${REPO_NAME} minor ${PINNED_MINOR} not yet in the Docker Hub tag listing (ALLOW_MISSING_PIN=1 — likely a forward-seeded pin awaiting upstream)" >&2
        printf '%s\n' "$available"
        exit 0
    fi
    echo "::error::Pinned ${REPO_NAME} minor ${PINNED_MINOR} not found in the Docker Hub tag listing. Likely causes: page_size cap silently lowered, name=${NAME_FILTER} filter regressed, ordering quirk dropping the pin mid-pagination, or response schema change. If using EVEN_MINORS_ONLY, check the pin is in the stable channel. Inspect the curl output and adjust the query." >&2
    exit 1
fi

printf '%s\n' "$available"
