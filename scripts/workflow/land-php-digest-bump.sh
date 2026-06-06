#!/usr/bin/env bash
# Lands a PHP-digest lockfile bump on `main` via a PR + auto-merge.
#
# Invoked by `.github/workflows/check-php.yml` when the probe step
# detects that `dev/php_digests.lock` is stale (a `php:X.Y-fpm-alpine`
# tag moved to a new digest, or a freshly-tracked minor needs a
# baseline seed). The probe writes the new lockfile to
# `/tmp/new_digests`; this script commits it on a content-addressed
# branch, opens a PR against `main`, dispatches the full-matrix build
# (digest-movement case only), and enables auto-merge (squash) so a
# green CI flips the bump in.
#
# Replaces a direct `git push HEAD:main`, which `main`'s branch
# protection rejects now that `ci-test aggregate` is a required status
# check — the bot's pushed commit carries no such status, so the push
# is declined and every cron iteration fails (GH-166/167). Routing the
# bump through a PR lets the required check run on the PR before merge.
#
# TOKEN REQUIREMENT: GH_TOKEN MUST be a classic PAT with `repo` +
# `workflow` scope (or a fine-grained PAT with contents + pull-requests
# + actions write). It CANNOT be the default GITHUB_TOKEN: (a) the "Allow
# GitHub Actions to create and approve pull requests" setting is off, so
# a GITHUB_TOKEN `gh pr create` is rejected, and (b) a GITHUB_TOKEN-
# authored PR does not trigger the `pull_request` CI the required check
# depends on, so auto-merge could never satisfy the gate. A PAT-authored
# PR runs CI normally, so auto-merge can land it. (The sibling
# check-versions.yml runs batch-bump under GITHUB_TOKEN and has never
# actually opened a PR in practice, so it is NOT a proven precedent for
# the token path — see the GH-166/167 follow-up ticket.)
#
# Required env vars:
#   GH_TOKEN            Inherited from the workflow step; the PAT above.
#                       Used by every gh CLI call and the tokenised push.
#   GITHUB_REPOSITORY   Default GitHub Actions env var; used to build
#                       the tokenised push remote (the checkout runs
#                       persist-credentials: false, so origin carries
#                       no stored credential).
#
# Optional env vars:
#   HAS_CHANGES   "true"  → a tracked minor's digest moved; dispatch a
#                           full-matrix rebuild before enabling
#                           auto-merge.
#                 other   → a new-minor baseline seed; land the
#                           lockfile but do NOT dispatch a rebuild (the
#                           minor-bump issue gates the human review).
#
# Exit codes:
#   0  Bump landed via PR + auto-merge, OR a no-op skip (an open
#      auto-bump PR already exists, the branch already carries PR
#      history, or the lockfile is already canonical).
#   1  Hard failure (missing env, gh/git broken, dispatch failed, or
#      auto-merge could not be enabled). notify-on-failure picks up
#      the alarm.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN env var is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var is required}"

HAS_CHANGES="${HAS_CHANGES:-false}"

# The probe step is the sole producer of /tmp/new_digests; without it
# there is nothing to land. Fail loud rather than committing a stale
# or empty lockfile.
[ -f /tmp/new_digests ] || {
    echo "::error::/tmp/new_digests not found — the probe step must run before this script"
    exit 1
}

# The bot identity that authors the bump commit; matches the actor
# github-actions uses for API calls so the commit links to the run.
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# The checkout runs persist-credentials: false (zizmor artipacked), so
# origin carries no stored credential. Push over an explicit tokenised
# URL; reads (git ls-remote) stay anonymous on this public repo.
push_remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# Refuse to open a second lockfile PR while a prior one is still open.
# Both would edit dev/php_digests.lock, so the second to merge would hit
# a content conflict and auto-merge would stall. Deferring is safe: once
# the open PR merges, the next cron re-detects any newer digest against
# the updated baseline and re-bumps.
#
# Scoped on the `auto-bump/php-digests-` branch prefix ALONE, NOT on the
# PR author. batch-bump-webtrees-versions.sh additionally filters
# `author.login == github-actions[bot]` because it runs under
# GITHUB_TOKEN, whose PRs are authored by the github-actions app. THIS
# script runs under a PAT (see check-php.yml), whose PRs are authored by
# the token owner's user account — an author filter would never match
# its own PRs and the guard would be dead. The prefix is cron-exclusive
# by convention, so prefix-only is the correct scope here. `--limit
# 1000` overrides gh's default 30 so a stale auto-bump PR cannot be
# paginated off behind unrelated open PRs.
open_auto_bumps=$(gh pr list --state open --limit 1000 --json number,headRefName,title --jq '
    [ .[]
      | select(.headRefName | startswith("auto-bump/php-digests"))
      | "\(.number) \(.headRefName) — \(.title)"
    ] | .[]') || {
    echo "::error::gh pr list failed when probing for open php-digest auto-bump PRs" >&2
    exit 1
}
if [ -n "$open_auto_bumps" ]; then
    echo "::notice::an open php-digest auto-bump PR already exists — skipping to avoid a conflicting second lockfile PR:"
    printf '%s\n' "$open_auto_bumps"
    echo "::notice::merge or close the listed PR and the next cron iteration will resume"
    exit 0
fi

# Content-address the branch on the new lockfile so a re-run with the
# same pending digests reuses the same branch (idempotent), while a
# newer digest set opens a distinct branch and a previously-merged
# branch never blocks it.
digest_hash=$(sha256sum /tmp/new_digests | cut -c1-12)
branch="auto-bump/php-digests-${digest_hash}"

# If the branch already exists on origin, only a true orphan (branch
# pushed but `gh pr create` never succeeded, so NO PR exists) is safe
# to delete + recreate. A branch with ANY PR — open (prior run),
# merged (already shipped), or closed-not-merged (maintainer rejected
# the bump) — must be preserved.
#
# `git ls-remote --exit-code` returns 0 = ref found, 2 = ref absent,
# and other codes (e.g. 128) on a real network/auth failure. Capture
# the code explicitly (the `|| ls_rc=$?` form keeps `set -e` from
# aborting on the expected exit-2) and distinguish absent (proceed)
# from a genuine error (bail loud) — a transient ls-remote failure must
# NOT be mistaken for "branch absent" and silently skip the idempotency
# guard.
ls_rc=0
git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || ls_rc=$?
if [ "$ls_rc" -eq 0 ]; then
    pr_count=$(gh pr list --head "$branch" --state all --json number --jq 'length') || {
        echo "::error::gh pr list failed for $branch" >&2
        exit 1
    }
    if [ "$pr_count" != "0" ]; then
        echo "Branch $branch already exists on origin with $pr_count PR(s) (any state) — skipping to preserve PR history"
        exit 0
    fi
    echo "::warning::orphan branch $branch exists without any PR — deleting so the bump can be recreated"
    git push "$push_remote" --delete "$branch" || {
        echo "::warning::failed to delete orphan branch $branch; manual cleanup required"
        exit 1
    }
elif [ "$ls_rc" -ne 2 ]; then
    echo "::error::git ls-remote failed for $branch with exit code $ls_rc (network/auth?), not the expected 2-for-absent" >&2
    exit 1
fi

git checkout -b "$branch"
mv /tmp/new_digests dev/php_digests.lock
git add dev/php_digests.lock

# Defensive: lockfile_dirty gated this script, but if main drifted to
# the new content between the probe and now, there is nothing to
# commit. Exit 0 — notify-on-failure should NOT fire.
if git diff --cached --quiet; then
    echo "::notice::dev/php_digests.lock already canonical; nothing to commit"
    exit 0
fi

if [ "$HAS_CHANGES" = "true" ]; then
    commit_msg="Update dev/php_digests.lock for PHP patch-level rebuild"
else
    commit_msg="Seed dev/php_digests.lock for new PHP minor"
fi
git commit -m "$commit_msg"
git push "$push_remote" "$branch"

pr_body="Automated PHP-digest lockfile bump opened by \`check-php.yml\`. "
if [ "$HAS_CHANGES" = "true" ]; then
    pr_body="${pr_body}A tracked \`php:X.Y-fpm-alpine\` tag moved to a new digest; the full-matrix build has been dispatched against this branch and auto-merge (squash) is enabled so a green CI ships the rebuilt images."
else
    pr_body="${pr_body}A freshly-tracked PHP minor needed a baseline digest seed. No rebuild is dispatched — the minor-bump issue gates the human review. Auto-merge (squash) is enabled so the seed lands once CI is green."
fi

# Self-heal: if `gh pr create` fails after the push lands, the branch
# is orphaned. Delete it so the next cron iteration recreates
# everything cleanly.
if ! pr_url=$(gh pr create \
    --title "$commit_msg" \
    --body "$pr_body" \
    --base main \
    --head "$branch"); then
    echo "::error::gh pr create failed for $branch; deleting orphan branch for self-healing next cron"
    git push "$push_remote" --delete "$branch" || \
        echo "::warning::failed to delete orphan branch $branch; manual cleanup required"
    exit 1
fi
echo "Opened PR: $pr_url"

# Dispatch the full-matrix rebuild BEFORE enabling auto-merge so the
# build run captures a valid `--ref` SHA before a fast CI-pass +
# auto-merge could delete the branch. Only on actual digest movement;
# a new-minor seed must go through the issue-only review path.
dispatch_failed=""
if [ "$HAS_CHANGES" = "true" ]; then
    if ! gh workflow run build.yml --ref "$branch"; then
        dispatch_failed=1
        echo "::warning::build.yml dispatch failed; auto-merge will stay off"
    fi
else
    echo "Seed mode: skipping build dispatch (the new-minor seed is gated by its bump issue)"
fi

# A merged-but-never-built lockfile is a permanent registry hole: the
# next cron sees the digest as the new baseline and never re-dispatches
# the rebuild. So if the dispatch failed, leave auto-merge OFF and exit
# non-zero — the PR stays open for human triage and notify-on-failure
# fires.
if [ -n "$dispatch_failed" ]; then
    echo "::error::build.yml dispatch failed for the digest rebuild; PR ${pr_url} left open for human triage — re-run: gh workflow run build.yml --ref ${branch}"
    exit 1
fi

if ! gh pr merge --auto --squash "$pr_url"; then
    echo "::error::gh pr merge --auto could not be enabled on ${pr_url}; merge manually after CI is green"
    exit 1
fi
echo "Auto-merge (squash) enabled on ${pr_url}; a green CI will flip the lockfile bump into main."
