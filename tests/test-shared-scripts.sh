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
mkdir -p "$land_dir/dev" "$land_dir/scripts/workflow" "$land_dir/scripts/lib"
cp "$repo_root/scripts/workflow/land-php-digest-bump.sh" "$land_dir/scripts/workflow/" 2>/dev/null || true
# land-php-digest-bump.sh sources ../lib/auto-bump-lib.sh; the copied
# script resolves it relative to its own dir, so the lib must travel too.
cp "$repo_root/scripts/lib/auto-bump-lib.sh" "$land_dir/scripts/lib/" 2>/dev/null || true

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
  "issue list") echo "" ;;
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
  "issue list") echo "" ;;
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
  "issue list") echo "" ;;
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
  "issue list") echo "" ;;
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
  "issue list") echo "" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
  "issue edit") exit 0 ;;
esac'
run_test \
    "notify-on-failure: assignment succeeds → 'Assigned' + exit 0" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    0 "Assigned https://github.com/o/r/issues/1"

# GH-174: dedup standing failures. The title no longer embeds `run N`,
# so the open-issue probe keys on a STABLE title. A standing daily
# failure must converge on ONE open tracking issue — commented on, never
# re-created. The stub is stateful: run 1 finds no open issue (so it
# files one and drops a marker), run 2 sees the marker (an open issue
# now exists) and must COMMENT, never call `issue create` a second time.
# Two consecutive runs are driven; `issue create` aborts loud if hit
# twice, proving the dedup holds.
reset_stubs
issue_marker="$stub_dir/.gh-issue-open"
# shellcheck disable=SC2016
stub gh "case \"\$1 \$2\" in
  'run view') echo '- check: https://x/job/1' ;;
  'issue list') if [ -f '$issue_marker' ]; then echo 42; fi ;;
  'issue create') if [ -f '$issue_marker' ]; then echo '::error::duplicate issue create' >&2; exit 99; fi; touch '$issue_marker'; echo 'https://github.com/o/r/issues/42' ;;
  'issue comment') echo 'https://github.com/o/r/issues/42#issuecomment-1' ;;
  'issue edit') exit 0 ;;
esac"
run_test \
    "notify-on-failure: standing failure → 2nd run comments, no duplicate (exit 0)" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh >/dev/null && $notify_env RUN_NUMBER=26 COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    0 "Commented on existing issue #42"

# GH-174: the comment path stops BEFORE the Copilot assignment block — a
# recurrence on an already-open, already-triaged issue must not re-file
# AND must not re-assign. Issue is open from the start (probe returns 42);
# both `issue create` and `issue edit` abort loud so a regression that
# fell through either is caught. COPILOT_PAT is set to prove the
# assignment block is skipped by the comment-path `exit 0`, not by a
# missing PAT.
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue list") echo "42" ;;
  "issue comment") echo "https://github.com/o/r/issues/42#issuecomment-1" ;;
  "issue create") echo "::error::standing failure must not re-file" >&2; exit 99 ;;
  "issue edit") echo "::error::comment path must not re-assign" >&2; exit 99 ;;
esac'
run_test \
    "notify-on-failure: open issue → comment only, no create + no re-assign (exit 0)" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    0 "Commented on existing issue #42"

# GH-174: transient single failure with no open issue → file a fresh one
# (the create path is preserved). The probe returns empty; commenting on
# a non-existent issue must never happen.
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue list") echo "" ;;
  "issue create") echo "https://github.com/o/r/issues/7" ;;
  "issue comment") echo "::error::must not comment when no open issue" >&2; exit 99 ;;
  "issue edit") exit 0 ;;
esac'
run_test \
    "notify-on-failure: no open issue → create fresh, no comment (exit 0)" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    0 "Issue created: https://github.com/o/r/issues/7"

# GH-174: the open-issue probe is fatal on a flaky `gh issue list` — a
# transient API error must NOT be misread as "no open issue" and silently
# re-file a duplicate.
reset_stubs
# shellcheck disable=SC2016
stub gh 'case "$1 $2" in
  "run view") echo "- check: https://x/job/1" ;;
  "issue list") echo "boom" >&2; exit 1 ;;
  "issue create") echo "::error::must not create after a failed probe" >&2; exit 99 ;;
esac'
run_test \
    "notify-on-failure: issue-list probe failure → ::error:: + exit 1" \
    "$notify_env COPILOT_PAT=pat ./scripts/workflow/notify-on-failure.sh" \
    1 "::error::gh issue list failed"

# ──────────────────────────────────────────────────────────────────────
# scripts/lib/auto-bump-lib.sh
#
# The four landing blocks both crons share live here (GH-171 §1). The
# functions `exit` directly (sourced into the caller), so each test
# sources the lib and calls the function under a stubbed git/gh PATH and
# asserts the exit code + annotation. Covering the lib directly means the
# webtrees batcher's orphan-branch path — too heavy to drive end-to-end
# (see the batch-bump carve-out above) — is still proven, because it now
# calls the very function tested below.
# ──────────────────────────────────────────────────────────────────────

# push-remote helper emits the tokenised URL from GH_TOKEN + repo.
reset_stubs
run_test \
    "auto-bump-lib: auto_bump_push_remote emits tokenised URL" \
    "source ./scripts/lib/auto-bump-lib.sh; GH_TOKEN=secret GITHUB_REPOSITORY=o/r auto_bump_push_remote" \
    0 "https://x-access-token:secret@github.com/o/r.git"

# Orphan guard: ls-remote network/auth error (exit 128) must bail loud,
# NOT be mistaken for "branch absent". This is the GH-166 hardening that
# previously lived only in the php-digest lander; routing both crons
# through this function back-ports it to the webtrees batcher (GH-171 §1).
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 128 ;; *) exit 0 ;; esac'
run_test \
    "auto-bump-lib: orphan guard ls-remote error (128) → ::error:: + exit 1" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_orphan_branch_guard br https://x" \
    1 "::error::git ls-remote failed"

# Orphan guard: branch absent (ls-remote exit 2) → proceed (return 0).
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 2 ;; *) exit 0 ;; esac'
run_test \
    "auto-bump-lib: orphan guard branch absent (exit 2) → proceed (exit 0)" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_orphan_branch_guard br https://x && echo PROCEED" \
    0 "PROCEED"

# Orphan guard: branch exists WITH a PR (any state) → preserve history.
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 0 ;; *) exit 0 ;; esac'
stub gh 'echo 1'
run_test \
    "auto-bump-lib: orphan guard branch+PR → skip (exit 0, preserve)" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_orphan_branch_guard br https://x" \
    0 "preserve PR history"

# Orphan guard: branch exists but the `gh pr list --head` probe fails →
# ::error:: + exit 1. WITHOUT this guard a failed probe would yield an
# empty pr_count, fall into the orphan-delete path, and force-delete a
# branch that may actually carry a PR. (Distinct from the open-PR guard's
# "gh pr list failed when probing" message above — this is the per-branch
# --head probe.)
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 0 ;; *) exit 0 ;; esac'
stub gh 'exit 1'
run_test \
    "auto-bump-lib: orphan guard --head probe failure → ::error:: + exit 1" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_orphan_branch_guard br https://x" \
    1 "::error::gh pr list failed for br"

# Orphan guard: branch exists with NO PR → delete orphan + proceed.
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 0 ;; push) echo "deleted $*"; exit 0 ;; *) exit 0 ;; esac'
stub gh 'echo 0'
run_test \
    "auto-bump-lib: orphan guard branch, no PR → delete + proceed" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_orphan_branch_guard br https://x && echo PROCEED" \
    0 "PROCEED"

# Open-PR guard: no matching open PR → proceed (return 0).
reset_stubs
stub gh 'echo ""'
run_test \
    "auto-bump-lib: open-PR guard no match → proceed (exit 0)" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_open_pr_guard auto-bump/php-digests label && echo PROCEED" \
    0 "PROCEED"

# Open-PR guard: gh pr list failure → ::error:: + exit 1.
reset_stubs
stub gh 'exit 1'
run_test \
    "auto-bump-lib: open-PR guard gh failure → ::error:: + exit 1" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_open_pr_guard auto-bump/php-digests label" \
    1 "::error::gh pr list failed"

# Open-PR guard: a FRESH open PR (created an hour ago) → normal skip
# (exit 0). The stub emits the lib's tab-delimited number/createdAt/rest.
reset_stubs
# shellcheck disable=SC2016
stub gh 'printf "43\t%s\tauto-bump/php-digests-xyz — fresh\n" "$(date -u -d @$(( $(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%SZ)"'
run_test \
    "auto-bump-lib: open-PR guard fresh PR → skip (exit 0)" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_open_pr_guard auto-bump/php-digests label" \
    0 "skipping"

# Open-PR guard stuck valve: a stale open PR (older than the 72h default)
# → ::error:: + exit 1 so notify-on-failure fires (GH-171 §3).
reset_stubs
# shellcheck disable=SC2016
stub gh 'printf "42\t2020-01-01T00:00:00Z\tauto-bump/php-digests-abc — stale\n"'
run_test \
    "auto-bump-lib: open-PR guard stale PR → ::error:: stuck + exit 1" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_open_pr_guard auto-bump/php-digests label" \
    1 "auto-merge appears stuck"

# Open-PR guard stuck valve is configurable: a 2020 PR is NOT stale when
# AUTO_BUMP_STALE_HOURS is cranked past its age → normal skip (exit 0).
reset_stubs
# shellcheck disable=SC2016
stub gh 'printf "42\t2020-01-01T00:00:00Z\tauto-bump/php-digests-abc — old-but-tolerated\n"'
run_test \
    "auto-bump-lib: open-PR guard AUTO_BUMP_STALE_HOURS override tolerates age" \
    "source ./scripts/lib/auto-bump-lib.sh; AUTO_BUMP_STALE_HOURS=10000000 auto_bump_open_pr_guard auto-bump/php-digests label" \
    0 "skipping"

# Orphan-delete failure must exit 1 (not silently proceed) so a
# half-cleaned branch surfaces via notify-on-failure. ls-remote=0 + no PR
# + a failing `git push --delete` drives the handler. Distinct from the
# token-leak test below, which swallows the exit code to isolate the
# no-leak assertion — this case pins the exit code itself.
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 0 ;; push) exit 1 ;; *) exit 0 ;; esac'
stub gh 'echo 0'
run_test \
    "auto-bump-lib: orphan-delete push failure → ::warning:: + exit 1" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_orphan_branch_guard br https://x" \
    1 "failed to delete orphan branch"

# Token-leak guard: the orphan-delete failure branch must report the
# branch name only, never the tokenised push remote. A regression that
# echoed $push_remote into a diagnostic would leak the PAT into the run
# log. ls-remote=0 + no PR + a failing `git push --delete` drives that
# branch; assert the secret sentinel never appears in the output.
reset_stubs
# shellcheck disable=SC2016
stub git 'case "$1" in ls-remote) exit 0 ;; push) exit 1 ;; *) exit 0 ;; esac'
stub gh 'echo 0'
# `|| true` swallows the guard's intended exit 1 (delete-failure) so the
# grep below — not pipefail on the failure path — decides the result:
# exit 1 (FAIL) only if the token sentinel leaked into the output.
run_test \
    "auto-bump-lib: orphan-delete failure never echoes the token" \
    "source ./scripts/lib/auto-bump-lib.sh; o=\$(auto_bump_orphan_branch_guard br 'https://x-access-token:SECRETTOKEN@github.com/o/r.git' 2>&1) || true; if grep -q SECRETTOKEN <<<\"\$o\"; then exit 1; fi" \
    0 ""

# Malformed createdAt must degrade to epoch 0 (treated as fresh, never
# stuck) and must NOT execute — the value is double-quoted into `date`,
# never eval'd. A garbage timestamp drives the `|| echo 0` fallback.
reset_stubs
# shellcheck disable=SC2016
stub gh 'printf "44\tnot-a-real-date\tauto-bump/php-digests-zzz — malformed ts\n"'
run_test \
    "auto-bump-lib: malformed createdAt degrades to fresh (exit 0)" \
    "source ./scripts/lib/auto-bump-lib.sh; auto_bump_open_pr_guard auto-bump/php-digests label" \
    0 "skipping"

# ──────────────────────────────────────────────────────────────────────
# scripts/bump/bump-mariadb.sh + bump-nginx.sh (operator docker wrappers)
# ──────────────────────────────────────────────────────────────────────

# Both wrappers mount the repo root at /app and run their Python bump
# from there, so the `-v` source MUST be the repo top — the directory
# that holds installer/webtrees_installer — not the scripts/ subdir the
# wrapper lives two levels under. Grouping the scripts into scripts/bump/
# (GH-121) added a directory level; a wrapper still walking a single `..`
# mounts scripts/, where the container can neither load the .py nor see
# the installer templates. Stub docker to inspect the -v source and
# assert it actually contains the installer tree.
# shellcheck disable=SC2016
_bump_mount_probe='src=""; while [ $# -gt 0 ]; do if [ "$1" = "-v" ]; then src="${2%%:*}"; fi; shift; done; if [ -d "$src/installer/webtrees_installer" ]; then echo MOUNT_OK; else echo "MOUNT_BAD=$src"; fi'

reset_stubs
stub docker "$_bump_mount_probe"
run_test \
    "bump-mariadb.sh: mounts the repo root (not scripts/) at /app" \
    "./scripts/bump/bump-mariadb.sh 11.9" \
    0 "MOUNT_OK"

reset_stubs
stub docker "$_bump_mount_probe"
run_test \
    "bump-nginx.sh: mounts the repo root (not scripts/) at /app" \
    "./scripts/bump/bump-nginx.sh 1.32" \
    0 "MOUNT_OK"

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
