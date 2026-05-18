#!/usr/bin/env bash
# Scan-poll-file-issue loop shared by every cron image poller
# (issue #140). Invoked by `.github/workflows/cron-docker-hub-poll.yml`;
# the env-var contract is documented there as the workflow_call
# inputs section. The mechanical `${X:?required}` guards below
# enforce the same contract at runtime — the YAML inputs are the
# single source of human-readable documentation.
#
# Lives as a standalone .sh (not inline in the workflow) so
# static analysis (ci-shellcheck) and any future tests/ harness can
# exercise the placeholder substitution + sort-V dedup paths in
# isolation.
#
# Side effects: opens one tracking issue per discovered newer minor
# via `scripts/workflow/file-bump-issue.sh`. Exits 0 even when zero
# new minors land — the cron is a poller, not a gate.

set -euo pipefail

: "${PINNED_MINOR:?required}"
: "${REPO_NAME:?required}"
: "${NAME_FILTER:?required}"
: "${REGEX:?required}"
: "${TITLE_TEMPLATE:?required}"
: "${BODY_TEMPLATE:?required}"
: "${IMAGE_LABEL:?required}"

echo "Pinned ${IMAGE_LABEL} minor: ${PINNED_MINOR}"

# Docker Hub polling + filter + pin-self-test all live in the shared
# script. The caller's REPO_NAME / NAME_FILTER / REGEX / STRIP_SUFFIX /
# EVEN_MINORS_ONLY env vars are passed through unchanged.
available=$(REPO_NAME="$REPO_NAME" \
    NAME_FILTER="$NAME_FILTER" \
    REGEX="$REGEX" \
    STRIP_SUFFIX="${STRIP_SUFFIX:-}" \
    EVEN_MINORS_ONLY="${EVEN_MINORS_ONLY:-0}" \
    PINNED_MINOR="$PINNED_MINOR" \
    ./scripts/workflow/check-docker-hub-minor.sh)

for ver in $available; do
    # Two-arg sort -V to enforce strict newness; identical-version
    # results from a duplicate Docker Hub listing skip cleanly.
    if [ "$(printf '%s\n%s\n' "$PINNED_MINOR" "$ver" | sort -V | head -1)" = "$PINNED_MINOR" ] \
        && [ "$ver" != "$PINNED_MINOR" ]; then
        # Substitute the ${VER} placeholder in the templates. `printf`
        # via process substitution + envsubst avoids shell-injection
        # risk that an `eval` form would carry, and keeps the
        # placeholder grammar simple (only ${VER} is recognised).
        # shellcheck disable=SC2016  # '${VER}' is an envsubst allowlist, not bash expansion
        title=$(VER="$ver" envsubst '${VER}' <<<"$TITLE_TEMPLATE")
        # shellcheck disable=SC2016  # see comment above
        body=$(VER="$ver" envsubst '${VER}' <<<"$BODY_TEMPLATE")
        TITLE="$title" BODY="$body" ./scripts/workflow/file-bump-issue.sh
    fi
done
