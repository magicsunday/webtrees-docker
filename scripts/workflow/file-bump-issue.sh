#!/usr/bin/env bash
# Idempotently files a tracking issue. If a same-titled issue
# already exists (any state — open, closed, merged-via-PR-trailer),
# this is a no-op so the cron loop converges without spamming
# duplicates on retried runs.
#
# Shared across the four `check-{alpine,mariadb,nginx,php}.yml`
# pollers. The variation per workflow is only title + body
# template; the issue-existence check and the gh CLI invocation
# are identical and benefit from being in one shellcheck-covered
# script.
#
# Required env vars:
#   TITLE          Exact issue title (used both as `--search` query
#                  and as the `--title` argument when filing).
#   BODY           Issue body content. Piped via stdin to gh issue
#                  create, so embedded newlines + markdown render
#                  correctly.
#   GH_TOKEN       (Inherited from caller's env) — required by gh.
#
# Stdout: the created issue URL on success (gh issue create's own
# stdout); empty if the issue already existed.
# Exit codes:
#   0  Issue exists or was created successfully.
#   1  gh issue list / create failure (transient API error, rate
#      limit, expired token). The caller's collect-then-fail
#      accumulator pattern surfaces this via notify-on-failure.
# A title-search failure is treated as fatal so a flaky gh CLI
# does not silently re-create an existing issue.

set -euo pipefail

: "${TITLE:?TITLE env var is required}"
: "${BODY:?BODY env var is required}"

# Use `gh ... --jq 'length'` (fuzzy `in:title` token search) rather
# than an exact-string post-filter so a maintainer who PREFIXES the
# auto-filed issue (e.g. `[deferred] Alpine 3.24 available — ...`)
# still trips the dedup guard. GitHub search uses AND-semantics on
# tokens, so a prefix-rename keeps every original token in the
# title and the search still finds the issue.
#
# Caveat: a SHORTENING rename that drops original tokens (e.g.
# renaming the alpine issue to `[deferred] Alpine 3.24 — busybox
# review pending` would drop `available`, `consider`, `bumping`,
# `installer/webtrees_installer/_alpine.py` from the title) breaks
# the AND-search and the next cron tick re-files a duplicate. Don't
# substantively shorten auto-filed issues — close them, label them,
# or prefix them instead.
#
# Token-search false-positives (`Alpine 3.24` matching an unrelated
# "Alpine" mention) are tolerable because the bot's title shapes
# include version-pinned tokens unlikely to collide.
if ! existing=$(gh issue list --state all --search "$TITLE in:title" --json number --jq 'length'); then
    echo "::error::gh issue list failed for '$TITLE'" >&2
    exit 1
fi

if [ "$existing" = "0" ]; then
    printf '%s' "$BODY" | gh issue create --title "$TITLE" --body-file -
fi
