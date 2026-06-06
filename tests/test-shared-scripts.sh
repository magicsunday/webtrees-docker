#!/usr/bin/env bash
# Failure-path tests for the workflow-shared scripts under
# `scripts/`. Mocks `curl` and `gh` via a PATH-shimmed stub
# directory so each negative path of the extracted scripts can be
# exercised in isolation. Runs locally via `make ci-shared-scripts-
# tests` and from `ci-test`.
#
# Coverage focus: every defensive branch that the four extracted
# scripts carry comments for. A regression that removes the `||
# true` after grep, the `// empty` jq guard, the
# `[ -n "$canonical_php" ] || exit 1` check, or the
# ALLOW_MISSING_PIN downgrade should fail at least one test here.

set -o errexit -o nounset -o pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

pass=0
fail=0
results=()

# Shared stub directory: every test resets it, drops in mocks for
# the binaries it needs, and prepends it to PATH so the script
# under test sees the stubs instead of the real binaries.
stub_dir=$(mktemp -d /tmp/wt-shared-scripts.XXXXXX)
trap 'rm -rf "$stub_dir"' EXIT

reset_stubs() {
    rm -rf "${stub_dir:?}"/*
}

stub() {
    local name=$1 body=$2
    cat > "$stub_dir/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$stub_dir/$name"
}

run_test() {
    local name=$1 cmd=$2 expect_rc=$3 expect_in_output=${4:-}
    local out rc
    set +e
    out=$(PATH="$stub_dir:$PATH" eval "$cmd" 2>&1)
    rc=$?
    set -e
    if [ "$rc" != "$expect_rc" ]; then
        echo "FAIL  $name: expected rc=$expect_rc, got rc=$rc"
        echo "      output (last 5 lines):"
        printf '%s\n' "$out" | tail -5 | sed 's/^/        /'
        fail=$((fail + 1))
        results+=("FAIL  $name")
        return
    fi
    # `grep -qF <<<` here-string instead of `printf | grep -qF`
    # pipeline — `grep -q` short-circuits on first match, SIGPIPEs
    # the upstream printf, which under `pipefail` propagates a
    # non-zero exit that the `! ... |` shape silently swallows.
    # AGENTS.md documents this trap.
    if [ -n "$expect_in_output" ] \
        && ! grep -qF "$expect_in_output" <<<"$out"; then
        echo "FAIL  $name: output does not contain '$expect_in_output'"
        echo "      output (last 5 lines):"
        printf '%s\n' "$out" | tail -5 | sed 's/^/        /'
        fail=$((fail + 1))
        results+=("FAIL  $name")
        return
    fi
    echo "PASS  $name"
    pass=$((pass + 1))
    results+=("PASS  $name")
}

# ──────────────────────────────────────────────────────────────────────
# scripts/workflow/check-docker-hub-minor.sh
# ──────────────────────────────────────────────────────────────────────

# Successful path with single tag matching the pin
reset_stubs
stub curl 'echo "{\"results\":[{\"name\":\"3.23\"}],\"next\":null}"'
run_test \
    "check-docker-hub-minor: happy path emits sorted available list" \
    "REPO_NAME=alpine NAME_FILTER=3. REGEX='^[0-9]+\\.[0-9]+\$' PINNED_MINOR=3.23 ./scripts/workflow/check-docker-hub-minor.sh" \
    0 "3.23"

# Pin not in listing — strict mode hard-fails
reset_stubs
stub curl 'echo "{\"results\":[{\"name\":\"3.20\"}],\"next\":null}"'
run_test \
    "check-docker-hub-minor: pin missing from listing → ::error:: + exit 1" \
    "REPO_NAME=alpine NAME_FILTER=3. REGEX='^[0-9]+\\.[0-9]+\$' PINNED_MINOR=3.23 ./scripts/workflow/check-docker-hub-minor.sh" \
    1 "::error::Pinned alpine minor 3.23 not found"

# Pin not in listing — ALLOW_MISSING_PIN downgrades to notice
reset_stubs
stub curl 'echo "{\"results\":[{\"name\":\"8.4-fpm-alpine\"}],\"next\":null}"'
run_test \
    "check-docker-hub-minor: ALLOW_MISSING_PIN=1 downgrades self-test to ::notice::" \
    "REPO_NAME=php NAME_FILTER=-fpm-alpine REGEX='^[0-9]+\\.[0-9]+-fpm-alpine\$' STRIP_SUFFIX='-fpm-alpine\$' ALLOW_MISSING_PIN=1 PINNED_MINOR=8.6 ./scripts/workflow/check-docker-hub-minor.sh" \
    0 "::notice::Pinned php minor 8.6 not yet"

# curl transient failure → ::warning:: + exit 0 (cron self-heals)
reset_stubs
stub curl 'exit 22'
run_test \
    "check-docker-hub-minor: curl failure → ::warning:: + exit 0" \
    "REPO_NAME=alpine NAME_FILTER=3. REGEX='^[0-9]+\\.[0-9]+\$' PINNED_MINOR=3.23 ./scripts/workflow/check-docker-hub-minor.sh" \
    0 "::warning::Docker Hub tag fetch failed"

# EVEN_MINORS_ONLY drops odd-minor pin → self-test fails
reset_stubs
stub curl 'echo "{\"results\":[{\"name\":\"1.27-alpine\"},{\"name\":\"1.30-alpine\"}],\"next\":null}"'
run_test \
    "check-docker-hub-minor: EVEN_MINORS_ONLY drops odd pin → self-test fails" \
    "REPO_NAME=nginx NAME_FILTER=alpine REGEX='^1\\.[0-9]+-alpine\$' STRIP_SUFFIX='-alpine\$' EVEN_MINORS_ONLY=1 PINNED_MINOR=1.27 ./scripts/workflow/check-docker-hub-minor.sh" \
    1 "::error::Pinned nginx minor 1.27 not found"

# Missing required env var bails out via `:?` guard
reset_stubs
run_test \
    "check-docker-hub-minor: missing REPO_NAME → bail with :? guard" \
    "unset REPO_NAME; NAME_FILTER=3. REGEX='^[0-9]+\\.[0-9]+\$' PINNED_MINOR=3.23 ./scripts/workflow/check-docker-hub-minor.sh" \
    1 "REPO_NAME"

# Jq tolerance: results-null doesn't crash mid-loop
reset_stubs
stub curl 'echo "{\"results\":null,\"next\":null}"'
run_test \
    'check-docker-hub-minor: .results=null tolerated by jq // empty guard' \
    "REPO_NAME=alpine NAME_FILTER=3. REGEX='^[0-9]+\\.[0-9]+\$' PINNED_MINOR=3.23 ./scripts/workflow/check-docker-hub-minor.sh" \
    1 "::error::Pinned alpine minor 3.23 not found"

# ALLOW_MISSING_PIN with EMPTY listing (filter regression) MUST still
# strict-fail — pin missing from a non-empty listing is the only
# legitimate "leading-pin" case.
reset_stubs
stub curl 'echo "{\"results\":[],\"next\":null}"'
run_test \
    "check-docker-hub-minor: ALLOW_MISSING_PIN does NOT mask empty-listing filter regression" \
    "REPO_NAME=php NAME_FILTER=-fpm-alpine REGEX='^[0-9]+\\.[0-9]+-fpm-alpine\$' STRIP_SUFFIX='-fpm-alpine\$' ALLOW_MISSING_PIN=1 PINNED_MINOR=8.6 ./scripts/workflow/check-docker-hub-minor.sh" \
    1 "::error::Pinned php minor 8.6 not found"

# Pagination: curl returns page1 with `next` URL, page2 closes. A
# state file tracks invocation count so the same `curl` stub binary
# can return different bodies per call.
reset_stubs
counter_file=$(mktemp /tmp/wt-pagination.XXXXXX)
echo 0 > "$counter_file"
stub curl "
count=\$(cat $counter_file)
echo \$((count + 1)) > $counter_file
if [ \"\$count\" = '0' ]; then
    echo '{\"results\":[{\"name\":\"3.22\"}],\"next\":\"https://hub.docker.com/page2\"}'
else
    echo '{\"results\":[{\"name\":\"3.23\"}],\"next\":null}'
fi
"
run_test \
    "check-docker-hub-minor: pagination follows .next URL until null" \
    "REPO_NAME=alpine NAME_FILTER=3. REGEX='^[0-9]+\\.[0-9]+\$' PINNED_MINOR=3.23 ./scripts/workflow/check-docker-hub-minor.sh" \
    0 "3.22"
rm -f "$counter_file"

# ──────────────────────────────────────────────────────────────────────
# scripts/workflow/file-bump-issue.sh
# ──────────────────────────────────────────────────────────────────────

# Issue already exists → no-op (no `gh issue create` call)
reset_stubs
# shellcheck disable=SC2016
# Single-quoted body is intentional: `$1`/`$2` are the gh-stub's
# OWN positional args at run time, not values to expand here.
stub gh 'if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo 1; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then echo "ERROR: should not create"; exit 99; fi'
run_test \
    "file-bump-issue: existing issue → no-op (no create call)" \
    "TITLE='Test issue' BODY='body' ./scripts/workflow/file-bump-issue.sh" \
    0 ""

# Issue does not exist → gh issue create invoked
reset_stubs
# shellcheck disable=SC2016
stub gh 'if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo 0; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then echo "https://github.com/test/issue/1"; exit 0; fi'
run_test \
    "file-bump-issue: new issue → gh issue create called" \
    "TITLE='Test issue' BODY='body' ./scripts/workflow/file-bump-issue.sh" \
    0 "https://github.com/test/issue/1"

# gh issue list failure → ::error:: + exit 1
reset_stubs
# shellcheck disable=SC2016
stub gh 'if [ "$1" = "issue" ] && [ "$2" = "list" ]; then exit 1; fi'
run_test \
    "file-bump-issue: gh issue list failure → ::error:: + exit 1" \
    "TITLE='Test issue' BODY='body' ./scripts/workflow/file-bump-issue.sh" \
    1 "::error::gh issue list failed"

# Missing required env var bails out
reset_stubs
run_test \
    "file-bump-issue: missing TITLE → bail with :? guard" \
    "unset TITLE; BODY='body' ./scripts/workflow/file-bump-issue.sh" \
    1 "TITLE"

# ──────────────────────────────────────────────────────────────────────
# scripts/workflow/probe-php-digests.sh
#
# Tests run in a tmp_dir holding a synthetic dev/versions.json +
# dev/php_digests.lock so the script's relative-path I/O lands on
# fixture data, not the real repo. GITHUB_OUTPUT points at a
# throwaway file the test inspects after each run.
# ──────────────────────────────────────────────────────────────────────

probe_dir=$(mktemp -d /tmp/wt-probe-php.XXXXXX)
trap 'rm -rf "$stub_dir" "$probe_dir"' EXIT
mkdir -p "$probe_dir/dev" "$probe_dir/scripts/workflow"
cp "$repo_root/scripts/workflow/probe-php-digests.sh" "$probe_dir/scripts/workflow/"

probe_setup() {
    local versions_json=$1 digests_lock=$2
    printf '%s' "$versions_json" > "$probe_dir/dev/versions.json"
    printf '%s' "$digests_lock" > "$probe_dir/dev/php_digests.lock"
    : > "$probe_dir/gh_output"
}

# Digest unchanged → no lockfile_dirty, no changes
reset_stubs
stub docker 'echo "sha256:aaa"'
probe_setup '[{"php":"8.5"}]' '8.5=sha256:aaa
'
run_test \
    "probe-php-digests: digest unchanged → no lockfile_dirty, no changes" \
    "cd $probe_dir && GITHUB_OUTPUT=$probe_dir/gh_output ./scripts/workflow/probe-php-digests.sh && ! grep -qF 'lockfile_dirty' $probe_dir/gh_output" \
    0 ""

# Digest changed → lockfile_dirty=true + changes block
reset_stubs
stub docker 'echo "sha256:bbb"'
probe_setup '[{"php":"8.5"}]' '8.5=sha256:aaa
'
run_test \
    "probe-php-digests: digest changed → lockfile_dirty=true + changes emitted" \
    "cd $probe_dir && GITHUB_OUTPUT=$probe_dir/gh_output ./scripts/workflow/probe-php-digests.sh && grep -qF 'lockfile_dirty=true' $probe_dir/gh_output && grep -qF '8.5 (sha256:aaa → sha256:bbb)' $probe_dir/gh_output" \
    0 ""

# New version with no baseline → silent seed, no changes, lockfile_dirty=true
reset_stubs
stub docker 'echo "sha256:ccc"'
probe_setup '[{"php":"8.5"}]' ''
run_test \
    "probe-php-digests: missing baseline → seed silently (no changes block)" \
    "cd $probe_dir && GITHUB_OUTPUT=$probe_dir/gh_output ./scripts/workflow/probe-php-digests.sh && grep -qF 'lockfile_dirty=true' $probe_dir/gh_output && ! grep -qF 'changes<<EOF' $probe_dir/gh_output" \
    0 "Seeding new digest for 8.5"

# Empty digest from docker buildx inspect → ::error:: + exit 1
reset_stubs
stub docker ''
probe_setup '[{"php":"8.5"}]' ''
run_test \
    "probe-php-digests: empty digest from docker inspect → ::error:: + exit 1" \
    "cd $probe_dir && GITHUB_OUTPUT=$probe_dir/gh_output ./scripts/workflow/probe-php-digests.sh" \
    1 "::error::failed to read digest for php:8.5"

# Missing GITHUB_OUTPUT env bails via :? guard
reset_stubs
probe_setup '[{"php":"8.5"}]' '8.5=sha256:aaa
'
run_test \
    "probe-php-digests: missing GITHUB_OUTPUT → bail with :? guard" \
    "cd $probe_dir && unset GITHUB_OUTPUT; ./scripts/workflow/probe-php-digests.sh" \
    1 "GITHUB_OUTPUT"

# ──────────────────────────────────────────────────────────────────────
# scripts/workflow/batch-bump-webtrees-versions.sh
#
# Only the trivial guard branches are covered here — the full
# orphan-branch / dispatch-accumulator / auto-merge-gate paths
# involve git push / gh pr create side effects that are heavy to
# stub. A future bats-style harness can extend this section. The
# guards covered now lock the contract for environments where
# REQUIRED env vars or basic catalog shape are missing.
# ──────────────────────────────────────────────────────────────────────

# Missing NEW_VERSIONS bails out
reset_stubs
run_test \
    "batch-bump-webtrees-versions: missing NEW_VERSIONS → bail with :? guard" \
    "unset NEW_VERSIONS; GH_TOKEN=stub ./scripts/workflow/batch-bump-webtrees-versions.sh" \
    1 "NEW_VERSIONS"

# Missing GH_TOKEN bails out (NEW_VERSIONS must be set first or the
# earlier :? guard fires; explicit unset of GH_TOKEN inside the
# subshell)
reset_stubs
run_test \
    "batch-bump-webtrees-versions: missing GH_TOKEN → bail with :? guard" \
    "(unset GH_TOKEN; NEW_VERSIONS=2.2.7 ./scripts/workflow/batch-bump-webtrees-versions.sh)" \
    1 "GH_TOKEN"

# NEW_VERSIONS of pure whitespace falls through the array-builder
# (every line is empty → continue) and hits the empty-array
# early-exit. Stub git + gh so the script reaches the guard without
# trying real network I/O. The guard prints `No new versions to
# batch` and exit 0.
reset_stubs
stub git ':'
stub gh 'echo "[]"'
run_test \
    "batch-bump-webtrees-versions: whitespace-only NEW_VERSIONS → exit 0 cleanly" \
    "NEW_VERSIONS=$'\n\n' GH_TOKEN=stub GITHUB_REPOSITORY=o/r ./scripts/workflow/batch-bump-webtrees-versions.sh" \
    0 "No new versions to batch"

# ──────────────────────────────────────────────────────────────────────
# scripts/lib/pull-or-fail.sh: docker pull wrapper. Failure-path tests
# pin every documented exit:
#   * exit 2 — missing argument
#   * exit 1 — bare-tag `repo:` (no tag)
#   * exit 1 — docker pull fails
#   * exit 0 — happy path
# ──────────────────────────────────────────────────────────────────────

reset_stubs
run_test \
    "pull-or-fail: no args → exit 2 + 'requires exactly one image reference'" \
    "./scripts/lib/pull-or-fail.sh" \
    2 "requires exactly one image reference"

reset_stubs
run_test \
    "pull-or-fail: bare-tag 'repo:' → exit 1 + 'missing a tag'" \
    "./scripts/lib/pull-or-fail.sh ghcr.io/example/foo:" \
    1 "missing a tag"

reset_stubs
# shellcheck disable=SC2016
# `$1` in the stub body is the stub's positional arg, expanded only
# when the stub is invoked. Single-quoting keeps it symbolic through
# the `stub` helper's heredoc.
stub docker '[ "$1" = "pull" ] && exit 1'
run_test \
    "pull-or-fail: pull fails → exit 1 + 'docker pull failed'" \
    "./scripts/lib/pull-or-fail.sh ghcr.io/example/foo:1.0" \
    1 "docker pull failed"

reset_stubs
# shellcheck disable=SC2016
stub docker '[ "$1" = "pull" ] && exit 0'
run_test \
    "pull-or-fail: happy path (pull succeeds) → exit 0" \
    "./scripts/lib/pull-or-fail.sh ghcr.io/example/foo:1.0" \
    0 ""

# ──────────────────────────────────────────────────────────────────────
# scripts/lib/render-make-help.sh: help renderer. `#` chars in
# descriptions (issue refs, $(VAR) refs) must survive the column-split
# unchanged.
# ──────────────────────────────────────────────────────────────────────

reset_stubs
fixture=$(mktemp /tmp/wt-help-fixture.XXXXXX)
cat > "$fixture" <<'FIXTURE'
#### Section A

target-one: ## Mentions $(SOME_VAR) which has a # char.
	echo one

target-two: ## Pure text description.
	echo two

#### Section B

target-three: ## Another with (issue #123) ref.
	echo three
FIXTURE
# shellcheck disable=SC2016
# Expected substring is matched literally; `$(SOME_VAR)` must NOT be
# bash-expanded — that's the regression we're guarding against.
run_test \
    "render-make-help: '#' in \$(VAR) survives column-split" \
    "FYELLOW='' FGREEN='' FRESET='' ./scripts/lib/render-make-help.sh $fixture" \
    0 'Mentions $(SOME_VAR) which has a # char'
run_test \
    "render-make-help: issue refs survive column-split" \
    "FYELLOW='' FGREEN='' FRESET='' ./scripts/lib/render-make-help.sh $fixture" \
    0 "Another with (issue #123) ref"
rm -f "$fixture"

reset_stubs
run_test \
    "render-make-help: no args → exit 1 + 'requires at least one Makefile'" \
    "./scripts/lib/render-make-help.sh" \
    1 "requires at least one Makefile"

# ──────────────────────────────────────────────────────────────────────
# scripts/workflow/land-php-digest-bump.sh
#
# Lands the probe step's `/tmp/new_digests` on `main` via a PR +
# auto-merge (squash) instead of a direct `git push HEAD:main`, which
# branch protection's required `ci-test aggregate` check rejects
# (GH-166/167). Tests cover the env `:?` guards, the open-PR /
# branch-history idempotency skips, and the dispatch ↔ auto-merge gate.
# The deep git side-effect paths (orphan-delete recreate) mirror
# batch-bump's "heavy to stub" carve-out and stay uncovered here.
#
# Happy-path tests run in a tmp working dir holding `dev/` so the
# lockfile `mv` lands on a throwaway, and seed a `/tmp/new_digests`
# the script hashes for its content-addressed branch name.
# ──────────────────────────────────────────────────────────────────────

land_dir=$(mktemp -d /tmp/wt-land-php.XXXXXX)
trap 'rm -rf "$stub_dir" "$probe_dir" "$land_dir"' EXIT
mkdir -p "$land_dir/dev" "$land_dir/scripts/workflow"
cp "$repo_root/scripts/workflow/land-php-digest-bump.sh" "$land_dir/scripts/workflow/" 2>/dev/null || true

land_setup() {
    printf '8.4=sha256:aaa\n8.5=sha256:bbb\n' > /tmp/new_digests
    printf '8.4=sha256:old\n8.5=sha256:old\n' > "$land_dir/dev/php_digests.lock"
}

# A git stub that fakes "branch does not exist on origin" (ls-remote
# exit 2) and "staged changes present" (diff --cached --quiet exit 1)
# so the happy paths flow through to commit/push without touching a
# real repo. Single-quoted: $1/$* are the stub's own runtime args.
# shellcheck disable=SC2016
git_happy_stub='case "$1" in
  ls-remote) exit 2 ;;
  diff) exit 1 ;;
  push) echo "git-push $*"; exit 0 ;;
  *) exit 0 ;;
esac'

# Missing GH_TOKEN bails out before any git/gh work
reset_stubs
run_test \
    "land-php-digest-bump: missing GH_TOKEN → bail with :? guard" \
    "(unset GH_TOKEN; GITHUB_REPOSITORY=o/r ./scripts/workflow/land-php-digest-bump.sh)" \
    1 "GH_TOKEN"

# Missing GITHUB_REPOSITORY bails out
reset_stubs
run_test \
    "land-php-digest-bump: missing GITHUB_REPOSITORY → bail with :? guard" \
    "(unset GITHUB_REPOSITORY; GH_TOKEN=stub ./scripts/workflow/land-php-digest-bump.sh)" \
    1 "GITHUB_REPOSITORY"

# An open bot-authored php-digest auto-bump PR already exists → skip to
# avoid a second conflicting lockfile PR.
reset_stubs
land_setup
# shellcheck disable=SC2016
stub git ':'
# shellcheck disable=SC2016
stub gh 'if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo "42 auto-bump/php-digests-abc — Update dev/php_digests.lock"; exit 0
fi'
run_test \
    "land-php-digest-bump: open auto-bump PR exists → skip (exit 0)" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r ./scripts/workflow/land-php-digest-bump.sh" \
    0 "skipping"

# Branch already exists on origin WITH a PR (any state) → skip to
# preserve PR history (closed-not-merged = maintainer rejection).
reset_stubs
land_setup
# ls-remote --exit-code succeeds (branch exists); everything else no-op.
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 0 ;; *) exit 0 ;; esac'
# shellcheck disable=SC2016
stub gh 'if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  for a in "$@"; do [ "$a" = "--state" ] && state=1; done
  # global open-PR guard passes (empty); branch --head probe returns 1
  if printf "%s\n" "$@" | grep -q -- "--head"; then echo 1; else echo ""; fi
  exit 0
fi'
run_test \
    "land-php-digest-bump: branch exists with PR history → skip (exit 0)" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r ./scripts/workflow/land-php-digest-bump.sh" \
    0 "preserve PR history"

# git ls-remote failing with a real error (network/auth, exit != 0/2)
# must bail loud, NOT be mistaken for "branch absent" and proceed.
reset_stubs
land_setup
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 128 ;; *) exit 0 ;; esac'
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in "pr list") echo "" ;; *) ;; esac'
run_test \
    "land-php-digest-bump: ls-remote network error (exit 128) → ::error:: + exit 1" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r ./scripts/workflow/land-php-digest-bump.sh" \
    1 "::error::git ls-remote failed"

# Happy path, HAS_CHANGES=true: opens a PR, dispatches the full-matrix
# build against the branch, enables auto-merge. The regression guard —
# it must NOT push straight to main.
reset_stubs
land_setup
stub git "$git_happy_stub"
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "pr list") echo "" ;;
  "pr create") echo "https://github.com/o/r/pull/7" ;;
  "workflow run") echo "DISPATCHED $*" ;;
  "pr merge") echo "MERGED $*" ;;
  *) ;;
esac'
run_test \
    "land-php-digest-bump: HAS_CHANGES=true → PR + dispatch + auto-merge" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r HAS_CHANGES=true ./scripts/workflow/land-php-digest-bump.sh" \
    0 "Auto-merge (squash) enabled"

# Happy path never pushes to main directly — assert the tokenised
# HEAD:main push of the old design is gone.
reset_stubs
land_setup
stub git "$git_happy_stub"
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "pr list") echo "" ;;
  "pr create") echo "https://github.com/o/r/pull/7" ;;
  "workflow run") echo "DISPATCHED $*" ;;
  "pr merge") echo "MERGED $*" ;;
  *) ;;
esac'
run_test \
    "land-php-digest-bump: never pushes HEAD:main (regression guard)" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r HAS_CHANGES=true ./scripts/workflow/land-php-digest-bump.sh 2>&1 | { ! grep -q 'HEAD:main'; }" \
    0 ""

# Seed path, HAS_CHANGES=false: lands the new-minor seed via PR +
# auto-merge but does NOT dispatch a rebuild (the minor-bump issue
# gates the human review).
reset_stubs
land_setup
stub git "$git_happy_stub"
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "pr list") echo "" ;;
  "pr create") echo "https://github.com/o/r/pull/8" ;;
  "workflow run") echo "SHOULD-NOT-DISPATCH $*"; exit 1 ;;
  "pr merge") echo "MERGED $*" ;;
  *) ;;
esac'
run_test \
    "land-php-digest-bump: HAS_CHANGES=false → seed via PR, no dispatch" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r HAS_CHANGES=false ./scripts/workflow/land-php-digest-bump.sh" \
    0 "Seed mode: skipping build dispatch"

# Dispatch failure must leave auto-merge OFF and exit non-zero so
# notify-on-failure fires (a merged-but-unbuilt lockfile is a
# permanent registry hole).
reset_stubs
land_setup
stub git "$git_happy_stub"
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "pr list") echo "" ;;
  "pr create") echo "https://github.com/o/r/pull/9" ;;
  "workflow run") exit 1 ;;
  "pr merge") echo "MERGED $*" ;;
  *) ;;
esac'
run_test \
    "land-php-digest-bump: build dispatch failure → exit 1, no auto-merge" \
    "cd $land_dir && GH_TOKEN=stub GITHUB_REPOSITORY=o/r HAS_CHANGES=true ./scripts/workflow/land-php-digest-bump.sh" \
    1 "::error::build.yml dispatch failed"

# ──────────────────────────────────────────────────────────────────────
# scripts/workflow/notify-on-failure.sh
#
# Files a tracking issue for a failed run and (optionally) assigns it
# to the Copilot agent. The fix the tests lock: an "agent not enabled"
# assignment failure degrades to a notice (exit 0) so a failure
# notification never turns its own job red, while a genuine token error
# still hard-fails (exit 1). gh is stubbed to drive each branch.
# ──────────────────────────────────────────────────────────────────────

# All notify env vars present except the one under test.
notify_env="WORKFLOW_NAME='Check for PHP updates' RUN_NUMBER=25 RUN_ID=999 RUN_URL=https://x/runs/999 EVENT_NAME=schedule REF_NAME=main GH_REPO=o/r GH_TOKEN=stub"

# Missing WORKFLOW_NAME bails via :? guard
reset_stubs
run_test \
    "notify-on-failure: missing WORKFLOW_NAME → bail with :? guard" \
    "(unset WORKFLOW_NAME; RUN_NUMBER=25 RUN_ID=999 RUN_URL=x EVENT_NAME=schedule REF_NAME=main ./scripts/workflow/notify-on-failure.sh)" \
    1 "WORKFLOW_NAME"

# No COPILOT_PAT → file issue, skip assignment with a notice (exit 0)
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
  "issue edit") echo "ERROR: should not assign without PAT" >&2; exit 99 ;;
esac'
run_test \
    "notify-on-failure: no COPILOT_PAT → skip assignment with notice (exit 0)" \
    "$notify_env ./scripts/workflow/notify-on-failure.sh" \
    0 "skipping Copilot auto-assignment"

# Copilot agent not enabled (replaceActorsForAssignable) → degrade to a
# notice, exit 0 (the GH-166/167 regression guard).
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
  "issue edit") echo "GraphQL: Copilot agent is not enabled in this repository. (replaceActorsForAssignable)" >&2; exit 1 ;;
esac'
run_test \
    "notify-on-failure: agent not enabled → notice, exit 0 (no red notify job)" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    0 "is not enabled in this repository"

# Genuine token misconfiguration → hard-fail (exit 1)
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
  "issue edit") echo "HTTP 401: Bad credentials" >&2; exit 1 ;;
esac'
run_test \
    "notify-on-failure: real token error → ::error:: + exit 1" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    1 "::error::Could not assign"

# Transient `gh run view` failure must NOT abort before the issue is
# filed — the notifier degrades to a placeholder and still creates the
# tracking issue (no COPILOT_PAT → assignment skipped).
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "boom" >&2; exit 1 ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
esac'
run_test \
    "notify-on-failure: gh run view failure → issue still filed (exit 0)" \
    "$notify_env ./scripts/workflow/notify-on-failure.sh" \
    0 "Issue created: https://github.com/o/r/issues/1"

# Happy path: assignment succeeds → exit 0
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
  "issue edit") exit 0 ;;
esac'
run_test \
    "notify-on-failure: assignment succeeds → 'Assigned' + exit 0" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    0 "Assigned https://github.com/o/r/issues/1"

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
