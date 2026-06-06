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
# GITHUB_REPOSITORY is a default GitHub Actions env var; the shared
# push-remote helper reads it.
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var is required}"

# shellcheck source=scripts/lib/auto-bump-lib.sh
source "$(dirname "$0")/../lib/auto-bump-lib.sh"

auto_bump_git_identity
push_remote=$(auto_bump_push_remote)

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

# Cross-cron split-batch guard: if ANY prior auto-bump PR in the
# `auto-bump/webtrees-` prefix family is still open, refuse to open a
# second one. Without this, a day-1 PR for {2.2.7} left open over a long
# weekend would collide with a day-2 batch covering {2.2.7, 2.2.8}: both
# PRs would add a 2.2.7 row to dev/versions.json, the second to merge
# would hit a content conflict, and the tracking-issue thread for 2.2.7
# would silently link to the wrong PR. The shared guard also fails loud
# if a matching open PR has wedged past AUTO_BUMP_STALE_HOURS so a stuck
# auto-merge surfaces instead of silently skipping every cron iteration.
auto_bump_open_pr_guard "auto-bump/webtrees-" "webtrees auto-bump"

# Skip the entire batch if the newest-version's branch already has ANY
# PR (open, closed, or merged): a prior cron's idempotency win, an
# already-shipped merge, or a maintainer's closed-not-merged rejection
# that must not be revived. Only a true orphan (branch exists but
# `gh pr create` never landed a PR) is deleted + recreated. The shared
# guard captures the ls-remote exit code explicitly so a transient
# network/auth failure bails loud rather than being mistaken for
# "branch absent" (the GH-166 hardening, previously only in the
# php-digest lander — GH-171 §1).
auto_bump_orphan_branch_guard "$batch_branch" "$push_remote"

# Snapshot the rolling-tag bundle and the PHP slot that currently
# carries `latest` BEFORE mutating the file. The NEWEST row inherits
# the bundle; the previous holder and every intermediate new row
# lose it. If no row carries `latest` something is off with
# versions.json — bail loud rather than silently shipping a release
# without rolling tags.
rolling=$(jq -c '[.[] | select(.tags | index("latest")) | .tags[]] | unique' dev/versions.json)
canonical_php=$(jq -r '.[] | select(.tags | index("latest")) | .php' dev/versions.json)
[ -n "$canonical_php" ] || { echo "::error::no row in dev/versions.json carries 'latest'"; exit 1; }
canonical_webtrees=$(jq -r '.[] | select(.tags | index("latest")) | .webtrees' dev/versions.json)
[ -n "$canonical_webtrees" ] || { echo "::error::no row in dev/versions.json carries 'latest' (webtrees field)"; exit 1; }

# The supported PHP minors are the single source of truth at
# `dev/php-versions.json`, modelled as a per-webtrees-minor map so
# branches that drop PHP support (e.g. webtrees 2.1.x not supporting
# PHP 8.5) keep an honest catalog. ci-php-versions-lockstep enforces
# that every existing webtrees row's PHP set equals
# `.supported[<wt-minor>]`, so the fan-out below extends that
# invariant to every new webtrees version with no hardcoded literal.
#
# Schema-shape validation routed through the same helper the
# lockstep checks use, so the cron pre-flight and the local lockstep
# agree on failure modes.
# shellcheck source=scripts/lib/images.env
source "$(dirname "$0")/../lib/images.env"
# shellcheck source=scripts/lib/php-versions-lib.sh
source "$(dirname "$0")/../lib/php-versions-lib.sh"
ci_validate_php_supported_shape "$(pwd)"
php_support_map=$(jq -c '.supported' dev/php-versions.json)

# Every new webtrees version must have a corresponding key in
# `.supported` — without it, the fan-out below would produce zero
# rows for that version and the next cron would re-detect it as
# "new" indefinitely. Pre-validate so notify-on-failure carries an
# actionable message.
for version in "${versions[@]}"; do
    wt_minor=$(ci_wt_minor_strip_patch "$version")
    has_key=$(jq -r --arg wt "$wt_minor" '.supported | has($wt)' dev/php-versions.json)
    if [ "$has_key" != "true" ]; then
        echo "::error::dev/php-versions.json \`.supported\` has no entry for webtrees minor '$wt_minor' (derived from new version '$version'). Add \`.supported[\"$wt_minor\"]\` before letting the cron bump this branch." >&2
        exit 1
    fi
done

# Cross-minor rolling-tag relocation guard.
#
# The fan-out below re-attaches the rolling-tag bundle (latest, major,
# minor) at `($ver == $newest and . == $php)`. If the newest version's
# minor differs from the prior latest row's minor, the bundle's minor
# tag would migrate from one webtrees branch onto another — e.g.
# bumping 2.1.28 while latest lives on 2.2.6 would tag the new 2.1.28
# image as `2.2`, silently mis-routing a `docker pull image:2.2` to
# the wrong branch. The PHP-membership proxy used in earlier iterations
# only caught this when the two branches' supported PHP sets were
# disjoint at canonical_php; an upstream PHP back-port to 2.1 would
# silently let the proxy pass while still mis-routing the minor tag.
# Direct minor-equality is the correct invariant.
newest_minor=$(ci_wt_minor_strip_patch "$newest")
canonical_minor=$(ci_wt_minor_strip_patch "$canonical_webtrees")
if [ "$newest_minor" != "$canonical_minor" ]; then
    echo "::error::cron cannot bump webtrees minor '$newest_minor' while the rolling 'latest' tag lives on minor '$canonical_minor' (row $canonical_webtrees). Relocating the rolling 'latest'/'$canonical_minor'/major tags across webtrees minors automatically would mis-route the minor tag to the new branch. Wait for the cron to detect the next release on the '$canonical_minor' branch, OR open a manual bump PR that moves 'latest' onto the new branch first." >&2
    exit 1
fi

# Sanity: with same-minor confirmed, the canonical PHP must still be
# a member of `.supported[<newest-minor>]`. Same-minor + supported-PHP
# drift can only happen if `.supported[<newest-minor>]` was hand-edited
# AFTER the cron started reading versions.json — i.e. main drifted
# between lockstep-green and the cron's execution window. Fail loud
# with a distinct diagnostic so the operator can tell intra-minor PHP
# drift from cross-minor relocation.
canonical_in_set=$(jq -r --arg wt "$newest_minor" --arg p "$canonical_php" '.supported[$wt] | index($p) != null' dev/php-versions.json)
if [ "$canonical_in_set" != "true" ]; then
    echo "::error::canonical PHP '$canonical_php' (from the prior 'latest' row $canonical_webtrees) is no longer in dev/php-versions.json \`.supported[\"$newest_minor\"]\`. dev/php-versions.json appears to have drifted between the lockstep-green commit and this cron invocation. Re-run \`make ci-php-versions-lockstep\` on main to confirm the drift, then re-run the cron." >&2
    exit 1
fi

# Build the new versions.json from the existing one plus one row per
# (new webtrees version × supported PHP minor for that version's
# branch). The newest version's row at canonical_php carries the
# rolling tag bundle; older intermediate versions in the batch open
# their slots empty.
versions_json=$(printf '%s\n' "${versions[@]}" | jq -R . | jq -sc .)
new_rows=$(jq -c \
    --arg newest "$newest" \
    --arg php "$canonical_php" \
    --argjson rolling "$rolling" \
    --argjson support_map "$php_support_map" \
    --argjson new_versions "$versions_json" '
    (map(.tags -= $rolling)
     + ($new_versions | map(. as $ver
        | ($ver | capture("^(?<m>[1-9][0-9]*\\.[0-9]+)") | .m) as $wt_minor
        | $support_map[$wt_minor]
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
git push "$push_remote" "$batch_branch"

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
    git push "$push_remote" --delete "$batch_branch" || \
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
