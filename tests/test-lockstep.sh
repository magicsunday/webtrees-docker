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

# Copy every pending change from the live repo into the worktree:
# tracked-modified + staged-new + truly-untracked. Called once at setup
# and again after each restore_worktree so the in-progress edit is
# visible to every test.
apply_overlay() {
    {
        git -C "$repo" diff --name-only -z HEAD
        git -C "$repo" ls-files --others --exclude-standard -z
    } | sort -uz | while IFS= read -r -d '' path; do
        [ -f "$repo/$path" ] || continue
        target_dir="$worktree/$(dirname "$path")"
        mkdir -p "$target_dir"
        cp -a "$repo/$path" "$target_dir/"
    done
}

# Stand up a clean copy of the working tree (HEAD, not the index). Each
# test mutates files inside the worktree freely; `git restore` between
# tests reverts the mutation so the next test starts from HEAD.
git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null

# Apply the pending-edit overlay so the harness exercises the
# in-progress edit, not just what's already committed.
apply_overlay

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
    # Revert tracked-file mutations only, then re-apply the pending-edit
    # overlay so tests 2..N exercise the same in-progress code as test 1.
    # `git checkout HEAD -- .` resets tracked files to HEAD, which would
    # erase any tracked-modified overlay (e.g. an edited Make/ci.mk);
    # the re-overlay step puts it back. We deliberately do NOT
    # `git clean -fd` here: it would sweep the untracked overlay files
    # (e.g. a not-yet-committed scripts/parse-alpine-pin.sh).
    #
    # New tests creating untracked artefacts inside $worktree need their
    # own bespoke cleanup — this restore intentionally only handles the
    # tracked-mutation revert.
    git -C "$worktree" checkout HEAD -- . >/dev/null 2>&1
    apply_overlay
}

# Run scripts/parse-alpine-pin.sh against an _alpine.py written from
# `fixture_content`, assert it prints `expected_pin` and exits 0.
assert_parser_outputs() {
    local name=$1 fixture_content=$2 expected_pin=$3
    local fixture_file="$worktree/installer/webtrees_installer/_alpine.py"
    local actual exit_code

    printf '%s\n' "$fixture_content" > "$fixture_file"

    set +e
    actual=$(cd "$worktree" && ./scripts/parse-alpine-pin.sh 2>/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        echo "FAIL  $name: parser exited $exit_code, expected 0"
        fail=$((fail + 1))
        results+=("FAIL  $name")
    elif [ "$actual" != "$expected_pin" ]; then
        echo "FAIL  $name: parser output '$actual', expected '$expected_pin'"
        fail=$((fail + 1))
        results+=("FAIL  $name")
    else
        echo "PASS  $name"
        pass=$((pass + 1))
        results+=("PASS  $name")
    fi
}

# Run scripts/parse-alpine-pin.sh against an _alpine.py written from
# `fixture_content`, assert it exits non-zero with `expect_in_stderr`
# present in its stderr (mirrors assert_lockstep_fails' contract so a
# regression in the *specific* failure message surfaces, not just any
# non-zero exit).
assert_parser_fails() {
    local name=$1 fixture_content=$2 expect_in_stderr=$3
    local fixture_file="$worktree/installer/webtrees_installer/_alpine.py"
    local stderr_out exit_code

    printf '%s\n' "$fixture_content" > "$fixture_file"

    set +e
    stderr_out=$(cd "$worktree" && ./scripts/parse-alpine-pin.sh 2>&1 >/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ]; then
        echo "FAIL  $name: expected non-zero exit, got 0"
        fail=$((fail + 1))
        results+=("FAIL  $name")
    elif ! printf '%s\n' "$stderr_out" | grep -qF "$expect_in_stderr"; then
        echo "FAIL  $name: stderr does not contain '${expect_in_stderr}'"
        echo "      actual stderr (last 5 lines):"
        printf '%s\n' "$stderr_out" | tail -5 | sed 's/^/        /'
        fail=$((fail + 1))
        results+=("FAIL  $name")
    else
        echo "PASS  $name"
        pass=$((pass + 1))
        results+=("PASS  $name")
    fi
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
# ci-healthcheck-lockstep — start_period drift between root + installer template
# ──────────────────────────────────────────────────────────────────────
# Helper: rewrite a `start_period:` line that lives AFTER `nginx:` to a
# specified value (or blank it). The two-step (grep -n + sed range)
# anchors the substitution to the nginx-or-later region of the file so
# db/phpfpm start_period lines above it cannot be mutated even if a
# future canonical value collides with theirs.
#
# The pre/post-mutation hash assertion guards against the canonical
# value ever leaving the `[0-9]+s` shape (e.g. someone bumping to `1m`):
# the sed pattern would no-op silently and the failure-path test would
# falsely succeed via assert_lockstep_fails seeing no drift. Fail loud
# so the helper itself trips before the recipe is even invoked.
mutate_nginx_start_period() {
    local file=$1 new_value=$2
    local nginx_line
    nginx_line=$(grep -n '^    nginx:' "$file" | head -1 | cut -d: -f1)
    [ -n "$nginx_line" ] || {
        echo "FAIL: $file has no '    nginx:' anchor (indent changed?)"
        return 1
    }
    local before_hash after_hash
    before_hash=$(md5sum "$file" | awk '{print $1}')
    sed -i "${nginx_line},\$ s|\\(start_period:\\) [0-9]*s|\\1 ${new_value}|" "$file"
    after_hash=$(md5sum "$file" | awk '{print $1}')
    if [ "$before_hash" = "$after_hash" ]; then
        echo "FAIL: mutate_nginx_start_period made no change to $file" \
             "— canonical start_period value may have left the [0-9]+s shape;" \
             "update the sed pattern in this helper"
        return 1
    fi
}

echo "Setting up: compose.yaml nginx start_period mutated to 99s"
mutate_nginx_start_period "$worktree/compose.yaml" "99s"
assert_lockstep_fails \
    "ci-healthcheck-lockstep: compose.yaml drift surfaces a clear error" \
    ci-healthcheck-lockstep \
    "start_period drift"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-healthcheck-lockstep — traefik-side drift
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: compose.traefik.j2 nginx start_period mutated to 99s"
# Exercises the traefik leg of the 3-way OR — without this case a
# regression that drops the traefik comparison would not be caught.
mutate_nginx_start_period \
    "$worktree/installer/webtrees_installer/templates/compose.traefik.j2" "99s"
assert_lockstep_fails \
    "ci-healthcheck-lockstep: traefik template drift surfaces a clear error" \
    ci-healthcheck-lockstep \
    "start_period drift"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-healthcheck-lockstep — start_period missing entirely on one side
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: installer template nginx start_period blanked"
# Blank the value (keep the key) so the file shape stays parseable and
# the failure is "not found", not a Jinja syntax error. Same anchored
# helper so db/phpfpm lines above nginx are never touched.
mutate_nginx_start_period \
    "$worktree/installer/webtrees_installer/templates/compose.standalone.j2" ""
assert_lockstep_fails \
    "ci-healthcheck-lockstep: blank start_period in template fails the lookup" \
    ci-healthcheck-lockstep \
    "start_period not found"
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
# scripts/parse-alpine-pin.sh — happy-path variants
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: parser fixture (canonical assignment)"
assert_parser_outputs \
    "parse-alpine-pin: canonical 'KEY = \"alpine:3.23\"'" \
    'ALPINE_BASE_IMAGE = "alpine:3.23"' \
    "alpine:3.23"
restore_worktree

echo "Setting up: parser fixture (Final[str] type annotation)"
assert_parser_outputs \
    "parse-alpine-pin: 'KEY: Final[str] = \"alpine:3.23\"'" \
    'ALPINE_BASE_IMAGE: Final[str] = "alpine:3.23"' \
    "alpine:3.23"
restore_worktree

echo "Setting up: parser fixture (indented + single quotes)"
assert_parser_outputs \
    "parse-alpine-pin: indented + single-quoted" \
    "    ALPINE_BASE_IMAGE = 'alpine:3.23'" \
    "alpine:3.23"
restore_worktree

echo "Setting up: parser fixture (inline comment with another alpine literal)"
# Verifies the sed extractor anchors on the RHS after `=`, not on any
# alpine literal that happens to appear later on the line (e.g. in a
# bump-history comment).
assert_parser_outputs \
    "parse-alpine-pin: inline comment with stray alpine literal is ignored" \
    'ALPINE_BASE_IMAGE = "alpine:3.23"  # was "alpine:9.99" before bump' \
    "alpine:3.23"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# scripts/parse-alpine-pin.sh — parse-failure path
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: parser fixture (no ALPINE_BASE_IMAGE assignment)"
assert_parser_fails \
    "parse-alpine-pin: empty file fails with parse error" \
    "# no pin defined here" \
    "Could not parse ALPINE_BASE_IMAGE"
restore_worktree

echo "Setting up: parser fixture (unquoted RHS)"
assert_parser_fails \
    "parse-alpine-pin: unquoted RHS fails with parse error" \
    'ALPINE_BASE_IMAGE = alpine:3.23' \
    "Could not parse ALPINE_BASE_IMAGE"
restore_worktree

echo "Setting up: parser fixture (non-alpine quoted RHS)"
assert_parser_fails \
    "parse-alpine-pin: non-alpine image rejected" \
    'ALPINE_BASE_IMAGE = "debian:bookworm"' \
    "Could not parse ALPINE_BASE_IMAGE"
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
