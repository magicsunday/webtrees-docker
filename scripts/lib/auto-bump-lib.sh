# =============================================================================
# Shared landing helpers for the auto-bump cron scripts.
# =============================================================================
#
# Sourced by both auto-bump landers:
#   * scripts/workflow/land-php-digest-bump.sh   (check-php.yml)
#   * scripts/workflow/batch-bump-webtrees-versions.sh (check-versions.yml)
#
# Both crons open an `auto-bump/<family>-…` branch, push it over a
# tokenised remote, open a PR against `main`, and enable auto-merge.
# The four blocks below were byte-near-identical copies that had already
# started to drift — the GH-166 ls-remote hardening landed in the
# php-digest lander but NOT in the webtrees-version batcher. Centralising
# them here means a fix to the guard logic lands in both crons at once
# (GH-171 §1).
#
# TOKEN MODEL: both callers now run under a repo-scoped PAT (COPILOT_PAT),
# NOT the default GITHUB_TOKEN. A GITHUB_TOKEN `gh pr create` is rejected
# by the "Allow GitHub Actions to create and approve pull requests" org
# setting, and a GITHUB_TOKEN-authored PR does not trigger the
# `pull_request` CI the required `ci-test aggregate` check depends on, so
# auto-merge could never satisfy the gate. A PAT-authored PR runs CI
# normally (GH-166/167, GH-171 §2). Because PRs are authored by the
# token owner's user account (not the github-actions app), the open-PR
# guard scopes on the branch PREFIX ALONE — an author filter would never
# match the cron's own PRs. The `auto-bump/<family>-` prefix is
# cron-exclusive by convention.
#
# CONTROL FLOW: the guards call `exit` directly (0 = skip cleanly, 1 =
# hard failure for notify-on-failure). Because the callers `source` this
# file, an `exit` here terminates the calling script — which is exactly
# the "skip the whole run" / "fail the whole run" semantics each guard
# needs. A bare `return` falls through so the caller proceeds.

# shellcheck shell=bash

# Configures the bot identity that authors the auto-bump commit. Matches
# the actor github-actions uses for API calls so the commit links to the
# workflow run in the UI.
auto_bump_git_identity() {
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
}

# Emits the tokenised push remote on stdout. The checkout runs
# persist-credentials: false (zizmor artipacked), so origin carries no
# stored credential; push over an explicit tokenised URL instead (reads
# via git ls-remote stay anonymous on this public repo). GH_TOKEN and
# GITHUB_REPOSITORY are guaranteed set by the caller's top-level `:?`
# guards before this runs.
auto_bump_push_remote() {
    printf 'https://x-access-token:%s@github.com/%s.git\n' "$GH_TOKEN" "$GITHUB_REPOSITORY"
}

# Refuses to open a second auto-bump PR while a prior one in the same
# branch-prefix family is still open. Both would edit the same catalog
# file, so the second to merge would hit a content conflict and stall
# auto-merge. Deferring is safe: once the open PR merges, the next cron
# re-detects any newer state against the updated baseline and re-bumps.
#
# `--limit 1000` overrides gh's default 30 so a stale auto-bump PR cannot
# be paginated off behind unrelated open PRs.
#
# Stuck-PR safety valve (GH-171 §3): a blocking PR whose auto-merge has
# wedged (e.g. CI stuck, a required check removed) would otherwise make
# every cron iteration exit 0 forever and the wedge would never surface.
# If any matching open PR is older than AUTO_BUMP_STALE_HOURS (default
# 72h), exit 1 so notify-on-failure fires instead of silently skipping.
#
# TRADE-OFF: the wedge is a STANDING condition, so the valve re-fires
# exit 1 on every subsequent cron until a human merges/closes the PR.
# scripts/workflow/notify-on-failure.sh keys its issue title on the
# per-run number and does not dedup, so a long-lived wedge files one
# duplicate tracking issue per day. Surfacing-repeatedly beats the
# pre-GH-171 never-surfacing, but the notifier-side dedup is a separate
# (all-crons) concern tracked in GH-174.
#
# Args:
#   $1  branch prefix to match (e.g. "auto-bump/php-digests")
#   $2  human label for the diagnostics (e.g. "php-digest auto-bump")
auto_bump_open_pr_guard() {
    local prefix=$1 label=$2
    local stale_hours="${AUTO_BUMP_STALE_HOURS:-72}"

    local open_prs
    open_prs=$(gh pr list --state open --limit 1000 \
        --json number,headRefName,title,createdAt --jq '
        [ .[]
          | select(.headRefName | startswith("'"$prefix"'"))
          | "\(.number)\t\(.createdAt)\t\(.headRefName) — \(.title)"
        ] | .[]') || {
        echo "::error::gh pr list failed when probing for open ${label} PRs" >&2
        exit 1
    }

    [ -n "$open_prs" ] || return 0

    local now stale_cutoff
    now=$(date -u +%s)
    stale_cutoff=$((now - stale_hours * 3600))

    echo "::notice::an open ${label} PR already exists — skipping to avoid a conflicting second PR:"
    local stuck="" number created rest created_epoch
    while IFS=$'\t' read -r number created rest; do
        [ -n "$number" ] || continue
        printf '%s\n' "$number $rest"
        # A genuinely malformed createdAt fails the parse (date exits
        # non-zero, stderr discarded) and degrades to epoch 0 via the
        # `|| echo 0`; the explicit `-ne 0` then keeps it out of the
        # stuck set so a parse hiccup cannot spuriously page the
        # maintainer. (`.createdAt` from gh is always a valid ISO-8601
        # timestamp for a real PR, so this is pure defence-in-depth.)
        created_epoch=$(date -u -d "$created" +%s 2>/dev/null || echo 0)
        if [ "$created_epoch" -ne 0 ] && [ "$created_epoch" -lt "$stale_cutoff" ]; then
            stuck="${stuck}#${number} "
        fi
    done <<< "$open_prs"

    if [ -n "$stuck" ]; then
        echo "::error::open ${label} PR(s) ${stuck% } are older than ${stale_hours}h — auto-merge appears stuck. Failing so notify-on-failure fires; investigate and merge or close the blocking PR(s)." >&2
        exit 1
    fi

    echo "::notice::merge or close the listed PR and the next cron iteration will resume"
    exit 0
}

# Idempotency guard for the content-/version-addressed bump branch. If
# the branch already exists on origin, only a true orphan (branch pushed
# but `gh pr create` never succeeded, so NO PR exists) is safe to delete
# + recreate. A branch with ANY PR — open (prior run), merged (already
# shipped), or closed-not-merged (maintainer rejected the bump) — must
# be preserved.
#
# `git ls-remote --exit-code` returns 0 = ref found, 2 = ref absent, and
# other codes (e.g. 128) on a real network/auth failure. Capture the
# code explicitly (`|| ls_rc=$?` keeps `set -e` from aborting on the
# expected exit-2) and distinguish absent (proceed) from a genuine error
# (bail loud) — a transient ls-remote failure must NOT be mistaken for
# "branch absent" and silently skip the idempotency guard (GH-166).
#
# Args:
#   $1  branch name
#   $2  tokenised push remote (from auto_bump_push_remote)
auto_bump_orphan_branch_guard() {
    local branch=$1 push_remote=$2

    local ls_rc=0
    git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || ls_rc=$?
    if [ "$ls_rc" -eq 0 ]; then
        local pr_count
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
}
