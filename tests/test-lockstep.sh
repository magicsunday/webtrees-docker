#!/usr/bin/env bash
#
# Failure-path tests for the Make `ci-*-lockstep` drift checks. Each test
# mutates a file in a throwaway git worktree to inject a known violation,
# then asserts that the relevant make target exits non-zero with the
# expected `::error::` annotation.
#
# Usage:
#   ./tests/test-lockstep.sh
#
# Exit codes:
#   0  all tests passed
#   1  at least one test failed

set -o errexit -o nounset -o pipefail

repo=$(git rev-parse --show-toplevel)
worktree_parent=$(mktemp -d)
worktree="${worktree_parent}/lockstep"

pass=0
fail=0
results=()

cleanup() {
    git -C "$repo" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$worktree_parent"
}
trap cleanup EXIT

# Stand up a clean copy of the working tree (HEAD, not the index). Each
# test mutates files inside the worktree freely; `git restore` between
# tests reverts the mutation so the next test starts from HEAD.
git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null

# Run a make target inside the worktree and capture exit code + stderr.
# Echoes "PASS" / "FAIL" + records into the result table.
#
# `cd "$worktree"` instead of `make -C` because some recipes substitute
# `$(PWD)` for the docker bind-mount source; Make's `$(PWD)` is
# inherited from the parent shell and is NOT updated by `-C`, so a
# `make -C` run would mount the original repo into docker even after a
# successful cwd change.
assert_lockstep_fails() {
    local name=$1 target=$2 expect_in_stderr=$3
    local stderr_out exit_code

    set +e
    stderr_out=$(cd "$worktree" && make "$target" 2>&1 >/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ]; then
        echo "FAIL  $name: expected non-zero exit, got 0"
        fail=$((fail + 1))
        results+=("FAIL  $name")
        return
    fi

    if ! printf '%s\n' "$stderr_out" | grep -qF "$expect_in_stderr"; then
        echo "FAIL  $name: stderr does not contain '${expect_in_stderr}'"
        echo "      actual stderr (last 5 lines):"
        printf '%s\n' "$stderr_out" | tail -5 | sed 's/^/        /'
        fail=$((fail + 1))
        results+=("FAIL  $name")
        return
    fi

    echo "PASS  $name"
    pass=$((pass + 1))
    results+=("PASS  $name")
}

restore_worktree() {
    git -C "$worktree" checkout HEAD -- . >/dev/null 2>&1
    git -C "$worktree" clean -fd >/dev/null 2>&1 || true
}

# ──────────────────────────────────────────────────────────────────────
# ci-alpine-lockstep — stray reference drift
# ──────────────────────────────────────────────────────────────────────
# `alpine:9.99` is guaranteed to differ from any real canonical pin so
# the test stays decoupled from the current ALPINE_BASE_IMAGE value.
echo "Setting up: stray alpine:9.99 reference in docs/customizing.md"
printf '\nalpine:9.99\n' >> "$worktree/docs/customizing.md"
assert_lockstep_fails \
    "ci-alpine-lockstep: stray alpine:9.99 reference fails the drift scan" \
    ci-alpine-lockstep \
    "Alpine pin drift detected"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-alpine-lockstep — malformed pin shape (X.Y.Z patch suffix)
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: ALPINE_BASE_IMAGE bumped to a patch-pinned alpine:3.23.4"
sed -i 's|^ALPINE_BASE_IMAGE.*$|ALPINE_BASE_IMAGE = "alpine:3.23.4"|' \
    "$worktree/installer/webtrees_installer/_alpine.py"
assert_lockstep_fails \
    "ci-alpine-lockstep: ALPINE_BASE_IMAGE='alpine:3.23.4' violates the minor-only pin policy" \
    ci-alpine-lockstep \
    "violates the minor-only pin policy"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — row 0 missing the `latest` tag
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json row 0 stripped of its tags"
# Drop the tags array on row 0 — simpler than a row swap, decoupled from
# whatever the rest of the array contains, and uses the same containerised
# jq the production lockstep recipe uses so the test stays host-tool-clean.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '.[0].tags = [] | .' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: row 0 without 'latest' tag fails the invariant" \
    ci-readme-badge-lockstep \
    'row 0 must carry the "latest" tag'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — README badge URL drifted away from `$[0].webtrees`
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README webtrees badge query changed to \$[*].webtrees"
sed -i 's|query=%24%5B0%5D.webtrees|query=%24%5B%2A%5D.webtrees|' "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: badge URL no longer queries \$[0].webtrees" \
    ci-readme-badge-lockstep \
    "no longer queries"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────
echo
for r in "${results[@]}"; do
    echo "$r"
done
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
