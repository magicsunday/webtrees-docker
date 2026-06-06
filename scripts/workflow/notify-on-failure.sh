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
#   WORKFLOW_NAME  Name of the failed workflow.
#   RUN_NUMBER     Per-workflow run counter (issue title).
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
# Exit codes:
#   0  Issue filed (assigned, assignment skipped, or assignment
#      degraded because the Copilot agent is not enabled).
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

title="CI failure: ${WORKFLOW_NAME} (run ${RUN_NUMBER})"
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
Workflow **${WORKFLOW_NAME}** failed. Triggered by \`${EVENT_NAME}\` on \`${REF_NAME}\`.

Run: ${RUN_URL}

Failed jobs:
${failed_jobs}

Reproduce locally or inspect the run logs above. Close this issue when the underlying failure is fixed.
BODY_END
)
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
