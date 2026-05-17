#!/usr/bin/env bash
# Atomic auto-bump for the daily upstream-webtrees-release cron.
#
# Invoked by `.github/workflows/check-versions.yml` when the find step
# emits at least one new upstream release in `$NEW_VERSIONS`. The
# script bumps `dev/versions.json` (one row per (new webtrees version
# × supported PHP minor)), rewrites README badges so the
# membership-strict `ci-readme-badge-lockstep` stays green, opens a
# single PR per cron iteration covering every new version, dispatches
# the build workflow for each, enables auto-merge (gated on all
# dispatches succeeding), refreshes the PR body with actual post-PR
# state, and files one tracking issue per new version.
#
# Required env vars:
#   NEW_VERSIONS   Newline-separated list of upstream-release tag
#                  names (e.g. `2.2.6\n2.2.7`) emitted by the find
#                  step. Routed through an env binding rather than
#                  `${{ … }}` interpolation so a hostile upstream
#                  tag cannot break out of the shell context at
#                  workflow-launch time.
#   GH_TOKEN       Inherited from the workflow step; required by
#                  every gh CLI call.
#
# Exit codes:
#   0  Bump succeeded (PR opened + merged-via-auto-merge OR no-op
#      branch already exists with PR history).
#   1  Hard failure (catalog malformed, gh CLI broken, push rejected,
#      or post-PR step failed in a way that needs human triage).
#      notify-on-failure picks up the alarm.
#
# The script extracts what used to live as a 400-line inline `run: |`
# block in the workflow. Extracting it lets shellcheck cover the
# bash, makes the failure-mode comments inspectable in isolation, and
# unblocks a future `bats`-style regression harness for the orphan-
# branch / auto-merge-gate / accumulator paths.

set -euo pipefail

: "${NEW_VERSIONS:?NEW_VERSIONS env var is required}"
: "${GH_TOKEN:?GH_TOKEN env var is required}"

# The bot identity that authors the auto-bump commit; matches the
# actor github-actions uses for API calls so the commit links to the
# workflow run in the UI.
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# Collect the new versions into an array. The find step's `new`
# output is newline-separated; preserve the natural `sort -V` order
# (oldest → newest) so the rolling-tag bundle ends up on the NEWEST
# version of the batch.
declare -a versions=()
while IFS= read -r v; do
    [ -z "$v" ] && continue
    versions+=("$v")
done <<< "$NEW_VERSIONS"

if [ ${#versions[@]} -eq 0 ]; then
    echo "No new versions to batch — exiting cleanly"
    exit 0
fi

newest=${versions[${#versions[@]}-1]}
batch_branch="auto-bump/webtrees-${newest}"

# Cross-cron split-batch guard: if ANY prior auto-bump PR authored by
# this workflow's bot is still open (matched on the
# `auto-bump/webtrees-` branch prefix), refuse to open a second one.
# Without this, a day-1 PR for {2.2.7} left open over a long weekend
# would collide with a day-2 batch covering {2.2.7, 2.2.8}: both PRs
# would add a 2.2.7 row to dev/versions.json, the second to merge
# would hit a content conflict, and the tracking-issue thread for
# 2.2.7 would silently link to the wrong PR.
#
# Scoped to PRs whose head commit was authored by the github-actions
# bot — so a maintainer-authored experimental branch matching the
# `auto-bump/webtrees-` prefix (hotfix, revert, spike) does NOT block
# the cron's regular operation. Filter post-API via jq instead of in
# the GitHub search query because `--search head:... author:...` only
# matches issue/PR authors, not commit authors, and gh-actions opens
# PRs with the runner's actor identity which may differ from the
# commit author. `--limit 1000` overrides gh's default 30. Without
# the override, a stale auto-bump PR could be paginated off the
# result by 30+ unrelated open PRs (community contributions,
# dependabot, etc.), the guard would see an empty list, and the
# duplicate-overlapping-PR cascade would re-open silently. 1000 is
# comfortably above any realistic open-PR ceiling for this project.
open_auto_bumps=$(gh pr list --state open --limit 1000 --json number,headRefName,title,author --jq '
    [ .[]
      | select(.headRefName | startswith("auto-bump/webtrees-"))
      | select(.author.login == "app/github-actions" or .author.login == "github-actions[bot]")
      | "\(.number) \(.headRefName) — \(.title)"
    ] | .[]') || {
    echo "::error::gh pr list failed when probing for open auto-bump PRs" >&2
    exit 1
}
if [ -n "$open_auto_bumps" ]; then
    echo "::notice::open bot-authored auto-bump PR(s) detected — skipping batch to avoid duplicate overlapping PRs:"
    printf '%s\n' "$open_auto_bumps"
    echo "::notice::merge or close the listed PR(s) and the next cron iteration will resume"
    exit 0
fi

# Skip the entire batch if the newest-version's branch already has
# ANY PR (open, closed, or merged). Querying `--state all` guards
# three distinct cases:
#   * open PR: a previous cron run already opened it, idempotency
#     win.
#   * merged PR: branch wasn't auto-deleted on merge; the version is
#     already shipped.
#   * closed-not-merged PR: maintainer rejected the bump. Reviving
#     it on every subsequent cron would undo the reviewer's
#     decision; refuse to delete a branch that carries human-curated
#     history.
# An "orphan" (branch exists but `gh pr create` failed mid-run, so
# NO PR ever existed) is the ONLY safe case for auto-delete +
# recreate.
if git ls-remote --exit-code --heads origin "$batch_branch" >/dev/null 2>&1; then
    pr_count=$(gh pr list --head "$batch_branch" --state all --json number --jq 'length') || {
        echo "::error::gh pr list failed for $batch_branch" >&2
        exit 1
    }
    if [ "$pr_count" != "0" ]; then
        echo "Branch $batch_branch already exists on origin with $pr_count PR(s) (any state) — skipping batch to preserve PR history"
        exit 0
    fi
    # No PR ever existed for this branch — treat as a true orphan
    # from a partial prior run. Delete-failure is a warning (mirrors
    # the post-`gh pr create` delete path for symmetric severity) so
    # a transient ref-lock or branch-protection rule does not lock
    # the workflow out of every subsequent cron iteration;
    # notify-on-failure carries the alarm via the explicit exit 1.
    echo "::warning::orphan branch $batch_branch exists without any PR — deleting so the batch can be recreated"
    git push origin --delete "$batch_branch" || {
        echo "::warning::failed to delete orphan branch $batch_branch; manual cleanup required"
        exit 1
    }
fi

# Snapshot the rolling-tag bundle and the PHP slot that currently
# carries `latest` BEFORE mutating the file. The NEWEST row inherits
# the bundle; the previous holder and every intermediate new row
# lose it. If no row carries `latest` something is off with
# versions.json — bail loud rather than silently shipping a release
# without rolling tags.
rolling=$(jq -c '[.[] | select(.tags | index("latest")) | .tags[]] | unique' dev/versions.json)
canonical_php=$(jq -r '.[] | select(.tags | index("latest")) | .php' dev/versions.json)
[ -n "$canonical_php" ] || { echo "::error::no row in dev/versions.json carries 'latest'"; exit 1; }

# The supported PHP minors are the single source of truth at
# `dev/php-versions.json`. ci-php-versions-lockstep enforces that
# every existing webtrees row already has one entry per supported
# minor, so the fan-out below extends that invariant to every new
# webtrees version with no hardcoded literal.
php_minors=$(jq -c '.supported' dev/php-versions.json)
[ -n "$php_minors" ] && [ "$php_minors" != "null" ] && [ "$php_minors" != "[]" ] || \
    { echo "::error::dev/php-versions.json missing or empty \`.supported\` array"; exit 1; }
# Shape gate: refuse to fan out values that aren't strict X.Y
# minors. Mirrors Make/ci.mk's ci-php-versions-lockstep regex.
jq -e 'all((.supported // [])[]; type == "string" and (. | test("^[1-9][0-9]*\\.[0-9]+$")))' dev/php-versions.json >/dev/null || \
    { echo "::error::dev/php-versions.json \`.supported\` contains a value not matching the strict X.Y minor shape; run \`make ci-php-versions-lockstep\` locally for the exact culprit"; exit 1; }

# Build the new versions.json from the existing one plus one row per
# (new webtrees version × supported PHP minor). The newest version's
# row at canonical_php carries the rolling tag bundle; older
# intermediate versions in the batch open their slots empty.
versions_json=$(printf '%s\n' "${versions[@]}" | jq -R . | jq -sc .)
new_rows=$(jq -c \
    --arg newest "$newest" \
    --arg php "$canonical_php" \
    --argjson rolling "$rolling" \
    --argjson minors "$php_minors" \
    --argjson new_versions "$versions_json" '
    (map(.tags -= $rolling)
     + ($new_versions | map(. as $ver
        | $minors
        | map({webtrees: $ver, php: ., tags: (if ($ver == $newest and . == $php) then $rolling else [] end)})) | add)
    )
    | [.[] | select(.tags | index("latest"))] + [.[] | select(.tags | index("latest") | not)]
    | .[]
' dev/versions.json \
    | sed -e 's/":"/": "/g' -e 's/":\[/": [/g' -e 's/,"/, "/g')

{
    printf '[\n'
    n=$(printf '%s\n' "$new_rows" | grep -c '')
    i=0
    while IFS= read -r row; do
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
            printf '    %s,\n' "$row"
        else
            printf '    %s\n' "$row"
        fi
    done <<< "$new_rows"
    printf ']\n'
} > dev/versions.json.new
mv dev/versions.json.new dev/versions.json

# Rewrite README badges in the same iteration so the auto-bump PR
# carries BOTH dev/versions.json AND README.md atomically.
# ci-readme-badge-lockstep is membership-strict and runs on every
# pull_request via ci-test.yml; a catalog-only commit would fail the
# lockstep and block its own auto-merge. The rewriter is idempotent
# — a no-op against an already-canonical README produces an empty
# diff that `git add` simply skips.
python3 scripts/rewrite-readme-badges.py

# PR title surfaces the count + newest version so the reviewer can
# scan the action at a glance. Body avoids forward-claiming dispatch
# + auto-merge state — both depend on later step outcomes that may
# fail. An unconditional "auto-merge is enabled" claim contradicts
# the gate below when a dispatch failure leaves auto-merge OFF,
# misleading reviewers into waiting on a stuck PR. The body is
# refreshed via `gh pr edit` after the dispatch + auto-merge gates
# decide so the human-visible state matches reality.
if [ ${#versions[@]} -eq 1 ]; then
    pr_title="Bump dev/versions.json for webtrees ${newest}"
    pr_body="Auto-detected new upstream release \`${newest}\`. The rolling \`latest\`/major/minor tags move to the new row on PHP ${canonical_php}; older rows keep only their version-pinned slot. README badges have been rewritten in the same commit to keep ci-readme-badge-lockstep green. Dispatch + auto-merge status will be updated in this body after the workflow's post-PR steps run."
else
    pr_title="Bump dev/versions.json for ${#versions[@]} webtrees releases (newest: ${newest})"
    # shellcheck disable=SC2016
    # Backticks are literal markdown code-span syntax, not shell
    # command substitution; the single-quoted format string is
    # intentional.
    versions_list=$(printf -- '- `%s`\n' "${versions[@]}")
    pr_body=$(printf '%s\n\n%s\n\n%s' \
        "Auto-detected ${#versions[@]} new upstream releases in the same cron window:" \
        "$versions_list" \
        "All rows opened in one commit. The rolling \`latest\`/major/minor tags move to the newest version \`${newest}\` on PHP ${canonical_php}; intermediate new versions open their PHP slots empty. README badges have been rewritten in the same commit to keep ci-readme-badge-lockstep green. Dispatch + auto-merge status will be updated in this body after the workflow's post-PR steps run.")
fi

git checkout -b "$batch_branch"
git add dev/versions.json README.md
# Guard against `nothing to commit`: if a maintainer had hand-edited
# `main` so that the jq fan-out + the rewriter both produce
# byte-identical output (rare but possible after manual
# reconciliation), `git commit` would exit non-zero under `set -e`
# and fail the entire step with no actionable signal. Detect that
# case explicitly and exit 0 — there is nothing to bump and
# notify-on-failure should NOT fire.
if git diff --cached --quiet; then
    echo "::notice::dev/versions.json + README.md already canonical for ${newest}; nothing to commit"
    exit 0
fi
git commit -m "$pr_title"
git push origin "$batch_branch"

# If `gh pr create` fails after the push lands, the branch is
# orphaned on the remote. Delete the branch so the next cron
# iteration's idempotency check recreates everything cleanly —
# without this, the batch stays stuck until a maintainer manually
# `git push origin --delete`s it.
if ! pr_url=$(gh pr create \
    --title "$pr_title" \
    --body "$pr_body" \
    --base main \
    --head "$batch_branch"); then
    echo "::error::gh pr create failed for $batch_branch; deleting orphan branch for self-healing next cron"
    git push origin --delete "$batch_branch" || \
        echo "::warning::failed to delete orphan branch $batch_branch; manual cleanup required"
    exit 1
fi

# Dispatch the build workflow for every new version against the
# batch branch BEFORE enabling auto-merge. If auto-merge fires
# before all dispatches land, the branch may be auto-deleted by a
# fast CI-pass + repo-level `delete branch on merge` and the
# remaining dispatches would target a missing ref. Dispatching first
# guarantees every build run has a valid `--ref` SHA captured at
# dispatch time. Failure on one dispatch must NOT short-circuit the
# remaining dispatches — accumulate and exit non-zero after the loop
# so notify-on-failure picks up the list.
dispatch_failures=""
for version in "${versions[@]}"; do
    if ! gh workflow run build.yml --ref "$batch_branch" -f webtrees_version="$version"; then
        dispatch_failures="${dispatch_failures}${version} "
        echo "::warning::build.yml dispatch for $version failed; loop continues, exit non-zero at end"
    fi
done

# Only enable auto-merge if EVERY dispatch landed. A
# partial-dispatch + auto-merge cascade ships a versions.json row
# claiming a version exists while no image was ever built for it;
# the next cron sees the version as "already in max_known" and
# never re-dispatches, leaving a permanent registry hole. Leaving
# auto-merge OFF keeps the PR open for human triage instead.
auto_merge_failure=""
if [ -z "$dispatch_failures" ]; then
    if ! gh pr merge --auto --squash "$pr_url"; then
        auto_merge_failure="$pr_url"
        echo "::warning::auto-merge could not be enabled on $pr_url; will surface as failure at end so notify-on-failure fires"
    fi
else
    echo "::warning::skipping gh pr merge --auto for $pr_url because ${dispatch_failures% } had dispatch failures; PR will stay open for human triage"
fi

# Refresh the PR body with the actual post-PR state so the
# human-readable description matches the workflow's downstream
# decisions. Reviewers reading the PR get the truth without digging
# through workflow logs. Failure surfaces via the final exit-gate
# (notify-on-failure) because a successful workflow run with a stale
# forward-claim body would mislead a reviewer waiting on the
# promised update.
if [ -n "$dispatch_failures" ]; then
    # Build re-run commands in ONE printf call with all ref+version
    # arg pairs flattened into an array. printf's format-spec-reuse
    # correctly walks (batch_branch, v1, batch_branch, v2, ...) and
    # emits one line per pair with newlines INSIDE printf's own
    # buffer (which `$()` preserves between lines and only strips
    # the trailing newline on the very last line). Mirrors the same
    # `printf ... "${array[@]}"` shape used to build `versions_list`
    # for the multi-version PR body above.
    #
    # The naive `for v; do x+=$(printf ... '\n'); done` form is
    # WRONG: command substitution strips the per-iteration trailing
    # `\n` before concatenation, collapsing all re-run commands onto
    # a single wall-of-text line in the PR body.
    fail_args=()
    for v in $dispatch_failures; do
        fail_args+=("$batch_branch" "$v")
    done
    # shellcheck disable=SC2016
    # Same as above — backticks are literal markdown for the PR
    # body's code-span rendering, not shell command substitution.
    fail_cmds=$(printf -- '  `gh workflow run build.yml --ref %s -f webtrees_version=%s`\n' "${fail_args[@]}")
    dispatch_status=$(printf -- '- ❌ Build dispatch FAILED for: %s — re-run manually:\n%s' \
        "${dispatch_failures% }" \
        "$fail_cmds")
else
    dispatch_status="- ✅ Build workflow dispatched for every version against \`${batch_branch}\`."
fi
if [ -n "$auto_merge_failure" ]; then
    merge_status="- ❌ \`gh pr merge --auto\` failed; merge this PR manually after CI is green."
elif [ -n "$dispatch_failures" ]; then
    merge_status="- ⚠️ Auto-merge SKIPPED because not every dispatch succeeded — human triage required before merging."
else
    merge_status="- ✅ Auto-merge (squash) enabled; a green CI will flip this PR in."
fi
updated_body=$(printf '%s\n\n## Workflow status\n%s\n%s\n' \
    "$pr_body" \
    "$dispatch_status" \
    "$merge_status")
# Body refresh failure is logged as a warning but does NOT exit 1 —
# the PR's functional state (auto-merge enabled, dispatches landed,
# tracking issues filed) is already correct, and a transient `gh pr
# edit` 5xx producing a stale forward-claim body is cosmetic.
# notify-on-failure escalation would page the maintainer for a
# problem that resolves the moment CI flips the PR in. The
# per-version tracking issues filed below carry the accurate
# dispatch+merge state independent of the PR body, so reviewers
# have a non-stale source of truth either way.
gh pr edit "$pr_url" --body "$updated_body" || \
    echo "::warning::failed to refresh PR body on $pr_url; per-version tracking issues still carry accurate state"

# File one tracking issue per new version, all pointing at the
# shared PR. Skip versions whose issue already exists (re-run after
# a transient failure). Collect-then-fail mirrors the dispatch loop
# above: a transient `gh issue create` 5xx on one version must NOT
# short-circuit the remaining issue creations, or later versions
# silently lose their tracking thread.
issue_failures=""
covers_list=$(printf '%s, ' "${versions[@]}" | sed 's/, $//')
for version in "${versions[@]}"; do
    issue_title="Webtrees ${version} released — bump dev/versions.json"
    # Pipe `gh` JSON output through a standalone `jq` invocation so
    # the title can be passed via `--arg` (parsed JSON string), not
    # concatenated into the jq source. `gh` does not forward
    # arbitrary jq flags to its embedded `--jq` engine; only its
    # own `--jq` flag is supported, and that flag accepts only a
    # filter string. The external-jq pipe sidesteps that limitation
    # so an upstream release tag containing `"` or `\` cannot break
    # the jq filter parse.
    if ! existing=$(gh issue list --state all --search "$issue_title in:title" --json title \
            | jq --arg t "$issue_title" '[.[] | select(.title == $t)] | length'); then
        issue_failures="${issue_failures}${version} "
        echo "::warning::gh issue list failed for '$issue_title'; loop continues, exit non-zero at end"
        continue
    fi
    # Mirror dispatch state in the issue body so the tracking thread
    # does not promise a run that never started. Matches the
    # dispatch-failure gate above: if this version is in
    # dispatch_failures, the issue points the maintainer at the
    # manual re-dispatch command.
    if [[ " ${dispatch_failures} " == *" ${version} "* ]]; then
        issue_dispatch_line="**Build workflow dispatch FAILED** for \`${version}\` — re-run manually: \`gh workflow run build.yml --ref ${batch_branch} -f webtrees_version=${version}\`."
    else
        issue_dispatch_line="Build workflow was dispatched against \`${batch_branch}\` with input \`webtrees_version=${version}\`; track the run in the Actions tab."
    fi
    if [ "$existing" = "0" ]; then
        if ! gh issue create \
            --title "$issue_title" \
            --body "Upstream released webtrees \`${version}\`. Batched auto-bump PR (covers ${covers_list}): ${pr_url}. ${issue_dispatch_line}"; then
            issue_failures="${issue_failures}${version} "
            echo "::warning::gh issue create failed for $version; loop continues, exit non-zero at end"
        fi
    else
        echo "Issue for $version already exists — skipping"
    fi
done

if [ -n "$dispatch_failures" ] || [ -n "$issue_failures" ] || [ -n "$auto_merge_failure" ]; then
    [ -n "$dispatch_failures" ] && echo "::error::build.yml dispatch failed for: ${dispatch_failures% }"
    [ -n "$issue_failures" ] && echo "::error::gh issue list/create failed for: ${issue_failures% }"
    [ -n "$auto_merge_failure" ] && echo "::error::gh pr merge --auto failed for: ${auto_merge_failure}"
    exit 1
fi
