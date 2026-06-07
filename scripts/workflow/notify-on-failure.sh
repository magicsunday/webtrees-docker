#!/usr/bin/env bash
# Opens a tracking issue for a failed workflow run and (optionally)
# assigns it to the Copilot Coding Agent.
#
# Extracted from `.github/actions/notify-on-failure/action.yml` so the
# bash is shellcheck-covered and its assignment-failure branches are
# exercised by `tests/test-shared-scripts.sh` — the same rationale that
# pulled batch-bump / probe / file-bump out of their workflows. The
# composite action invokes it in a job gated on `failure() &&
# github.event_name != 'pull_request'`.
#
# Required env vars (the composite action sets all of these from the
# github context):
#   WORKFLOW_NAME  Name of the failed workflow (the stable dedup title).
#   RUN_NUMBER     Per-workflow run counter (issue/comment body only).
#   RUN_ID         Run id (gh run view + run URL).
#   RUN_URL        Web URL of the failed run (issue body).
#   EVENT_NAME     Triggering event (issue body).
#   REF_NAME       Triggering ref (issue body).
#   GH_TOKEN       Consumed by the gh CLI for issue creation.
#   GH_REPO        Repo override consumed by the gh CLI.
#
# Optional env vars:
#   COPILOT_PAT  PAT used to assign the issue to copilot-swe-agent
#                (the default GITHUB_TOKEN cannot assign bot accounts).
#                Unset → skip the assignment with a notice.
#
# Dedup (GH-174): the issue title is keyed on WORKFLOW_NAME alone — the
# per-run counter lives in the body, not the title. Before filing, an
# OPEN issue with the same title is probed; if one exists the run appends
# a recurrence comment instead of opening a duplicate. A standing daily
# failure (e.g. a wedged auto-bump PR that the GH-171 stuck-PR valve
# fails every cron tick) therefore converges on ONE tracking issue rather
# than storming the tracker with one new issue per run.
#
# Exit codes:
#   0  Issue filed or commented (assigned, assignment skipped, or
#      assignment degraded because the Copilot agent is not enabled).
#   1  Hard failure: gh issue create broke, or the assignment failed
#      with a genuine token misconfiguration (wrong scope / expired) —
#      NOT the environmental "agent not enabled" case.

set -euo pipefail

: "${WORKFLOW_NAME:?WORKFLOW_NAME env var is required}"
: "${RUN_NUMBER:?RUN_NUMBER env var is required}"
: "${RUN_ID:?RUN_ID env var is required}"
: "${RUN_URL:?RUN_URL env var is required}"
: "${EVENT_NAME:?EVENT_NAME env var is required}"
: "${REF_NAME:?REF_NAME env var is required}"

title="CI failure: ${WORKFLOW_NAME}"
# `gh run view` is network I/O; a transient failure (5xx, rate limit,
# run not yet queryable) must NOT abort before the issue is filed —
# otherwise this notifier swallows its own purpose AND turns its own job
# red. Degrade to a placeholder so the tracking issue (with the run URL)
# always lands; the run page still carries the per-job detail.
failed_jobs=$(gh run view "${RUN_ID}" --json jobs \
    --jq '.jobs[] | select(.conclusion == "failure") | "- \(.name): \(.url)"') \
    || failed_jobs='(could not enumerate failed jobs — inspect the run URL above)'

# The heredoc body sits at column 0 so the rendered issue carries no
# leading whitespace — the same output the YAML block scalar produced
# after its common-indent strip.
body=$(cat <<BODY_END
Workflow **${WORKFLOW_NAME}** failed (run ${RUN_NUMBER}). Triggered by \`${EVENT_NAME}\` on \`${REF_NAME}\`.

Run: ${RUN_URL}

Failed jobs:
${failed_jobs}

Reproduce locally or inspect the run logs above. Close this issue when the underlying failure is fixed.
BODY_END
)

# Probe for an already-open tracking issue with the same stable title
# before filing (GH-174). OPEN-only on purpose: a CLOSED issue means the
# failure was resolved, so a fresh recurrence deserves a new issue rather
# than resurrecting a closed one. The quoted `in:title "<phrase>"` search
# narrows server-side (the title's colon is literal inside quotes, not a
# `qualifier:` token); the exact-title jq post-filter via `env.GH174_TITLE`
# then rejects a longer title that merely CONTAINS the phrase (another
# workflow whose name extends this one). A probe failure is FATAL — a
# flaky `gh issue list` must not be misread as "no open issue" and
# silently re-file a duplicate.
if ! existing_number=$(GH174_TITLE="$title" gh issue list \
        --state open --search "in:title \"${title}\"" --json number,title \
        --jq 'map(select(.title == env.GH174_TITLE)) | first | .number // empty'); then
    echo "::error::gh issue list failed probing for an open '$title' issue" >&2
    exit 1
fi

if [ -n "$existing_number" ]; then
    # Standing failure: the tracking issue is already open (and already
    # triaged/assigned on creation). Append a recurrence comment and stop
    # — no duplicate issue, no re-assignment.
    comment_url=$(gh issue comment "$existing_number" --body "$body")
    echo "Commented on existing issue #${existing_number}: $comment_url"
    exit 0
fi

issue_url=$(gh issue create --title "$title" --body "$body")
echo "Issue created: $issue_url"

if [ -z "${COPILOT_PAT:-}" ]; then
    echo "::notice::COPILOT_PAT secret not set — skipping Copilot auto-assignment. Add a PAT to enable hands-off triage."
    exit 0
fi

# COPILOT_PAT is intentionally set, so an assignment failure is normally
# a configuration bug (wrong scope, expired token) worth failing the
# step over. The ONE exception is "Copilot Coding Agent is not enabled
# in this repository" (GraphQL replaceActorsForAssignable): that is an
# environmental opt-in, not a broken token, and the tracking issue is
# already filed. Degrading to a notice there stops EVERY failure
# notification from turning its own notify job red, while still
# surfacing a genuine token misconfiguration loudly.
if assign_err=$(GH_TOKEN="${COPILOT_PAT}" gh issue edit "$issue_url" \
        --add-assignee "copilot-swe-agent[bot]" 2>&1); then
    echo "Assigned $issue_url to copilot-swe-agent[bot]"
elif printf '%s' "$assign_err" | grep -qiE 'replaceActorsForAssignable|copilot.*not enabled'; then
    echo "::notice::Copilot Coding Agent is not enabled in this repository — filed $issue_url without auto-assignment. Enable the agent in repo settings for hands-off triage."
else
    printf '%s\n' "$assign_err" >&2
    echo "::error::Could not assign $issue_url to Copilot. Verify (a) COPILOT_PAT has 'repo' scope (classic) or 'issues:write' + 'metadata:read' (fine-grained), (b) the token has not expired."
    exit 1
fi
