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

# Positive-control: the recipe must exit 0 after the worktree mutation.
# Used when the test asserts that a defensive code path (e.g. type
# guard, natural sort) keeps a malformed-but-recoverable input
# acceptable.
assert_lockstep_passes() {
    local name=$1 target=$2
    local stderr_out exit_code

    set +e
    stderr_out=$(cd "$worktree" && make "$target" 2>&1 >/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        echo "FAIL  $name: expected exit 0, got $exit_code"
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
# ci-readme-badge-lockstep — new unique webtrees value not encoded in badge
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json grows a new unique webtrees value"
# Append a row carrying a webtrees value the README badge does not encode.
# Uses the same containerised jq the production lockstep recipe uses so
# the test stays host-tool-clean.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"9.9.9","php":"8.5","tags":[]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: new unique webtrees value missing from badge fails" \
    ci-readme-badge-lockstep \
    'webtrees badge does not encode'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — natural-sort ordering against 2-digit minor
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json grows PHP 8.10; README must encode 8.3|8.4|8.5|8.10"
# Adds a row with PHP 8.10 (and an existing webtrees value so the
# webtrees badge stays satisfied). The recipe's natural-sort
# `tonumber? // 0` clause must place 8.10 AFTER 8.5; a regression to
# plain lexical `sort` would emit `8.10|8.3|8.4|8.5` and the README
# would have to be rewritten in the wrong order — this test pins the
# natural-sort contract by overwriting the README badge to the
# natural-order spelling and asserting the recipe accepts it.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"2.2.6","php":"8.10","tags":[]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
sed -i 's|PHP-8.3%7C8.4%7C8.5-787CB5|PHP-8.3%7C8.4%7C8.5%7C8.10-787CB5|' "$worktree/README.md"
assert_lockstep_passes \
    "ci-readme-badge-lockstep: PHP 8.10 lands AFTER 8.5 (natural sort)" \
    ci-readme-badge-lockstep
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — schema-bad row (non-string php value)
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json row carries a non-string php value"
# Integer in .php would crash `split(.)` without the `type == \"string\"`
# guard. The defensive filter must drop the row so the badge check
# either passes (clean current state) or fails with the actionable
# `empty pin extraction` message — never with a generic docker error.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"2.2.6","php":83,"tags":[]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_passes \
    "ci-readme-badge-lockstep: non-string php row dropped by type guard" \
    ci-readme-badge-lockstep
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — hyphen-bearing badge message blocks naive sed
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README badge message already contains a hyphen (pre-release-style)"
# Hyphen-tolerance trap: if a previous bump left a pre-release
# value (`2.3.0-beta.1`) in the badge message, a naive
# `sed s|webtrees-[^-]+-blue|...|` cannot match (the `[^-]+` cannot
# cross the embedded `-`). The recipe must still catch this state
# loud — the python-based rewriter in check-versions.yml accepts
# hyphens, but if a future maintainer "simplifies" the renderer to
# use the naive sed, the lockstep recipe should still flag the drift
# at the consumer side.
sed -i 's|webtrees-2.1.27%7C2.2.6-blue|webtrees-2.1.27%7C2.2.6%7C2.3.0-beta.1-blue|' "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: hyphen-bearing badge value not in versions.json fails" \
    ci-readme-badge-lockstep \
    'webtrees badge does not encode'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — check-versions.yml renderer dropped README sync
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: simulate check-versions.yml renderer adding a webtrees row but skipping README"
# The cron-driven auto-bump appends new versions.json rows + opens a PR
# with auto-merge enabled. If a future renderer regression skipped the
# README badge rewrite step in check-versions.yml, the PR would silently
# block on lockstep failure. This test pins that the recipe DOES catch
# the cascade — the auto-bump must keep README in sync with versions.json.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"2.2.7","php":"8.5","tags":["latest"]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: renderer added webtrees row without README sync fails" \
    ci-readme-badge-lockstep \
    'webtrees badge does not encode'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — empty versions.json
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json = [] (empty)"
echo '[]' > "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: empty versions.json fails with actionable message" \
    ci-readme-badge-lockstep \
    'empty pin extraction'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-php-versions-lockstep — supported PHP minors drift from versions.json rows
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: versions.json keeps 8.3/8.4/8.5 rows, php-versions.json drops 8.3"
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '.supported = ["8.4", "8.5"]' php-versions.json > "$worktree/dev/php-versions.json.new"
mv "$worktree/dev/php-versions.json.new" "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: shrinking .supported without dropping versions.json rows fails" \
    ci-php-versions-lockstep \
    'carry PHP'
restore_worktree

# Symmetric: versions.json gains a 9.0 row but php-versions.json
# `.supported` still excludes it. The bumper would never produce
# this state, but a hand-edit could; the lockstep catches both
# directions.
echo "Setting up: versions.json gains a 9.0 row, php-versions.json unchanged"
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"2.2.6","php":"9.0","tags":[]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: extending versions.json without bumping .supported fails" \
    ci-php-versions-lockstep \
    'carry PHP'
restore_worktree

# php-versions.json missing the `.supported` key entirely.
echo "Setting up: php-versions.json has no .supported key"
echo '{}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: missing .supported key fails with actionable message" \
    ci-php-versions-lockstep \
    'missing, empty, or not an array'
restore_worktree

# php-versions.json not parseable.
echo "Setting up: php-versions.json malformed"
echo 'not json {{{' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: malformed php-versions.json fails loud" \
    ci-php-versions-lockstep \
    'not parseable JSON'
restore_worktree

# Duplicate entries in .supported (a hand-edit typo: `["8.3", "8.3", "8.5"]`).
echo "Setting up: php-versions.json .supported has duplicates"
echo '{"supported": ["8.3", "8.3", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: duplicate entries in .supported fail loud" \
    ci-php-versions-lockstep \
    'contains duplicates'
restore_worktree

# Non-string entry in .supported (`[8.3, "8.4", "8.5"]` — first is a number).
echo "Setting up: php-versions.json .supported has a non-string entry"
echo '{"supported": [8.3, "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: non-string entry in .supported fails loud" \
    ci-php-versions-lockstep \
    'non-strings'
restore_worktree

# Whitespace-bearing entry in .supported (`["8.3 ", "8.4"]` — trailing space).
echo "Setting up: php-versions.json .supported has whitespace-bearing entry"
echo '{"supported": ["8.3 ", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: whitespace-bearing entry in .supported fails loud" \
    ci-php-versions-lockstep \
    'whitespace-bearing'
restore_worktree

# Empty .supported array — a hand-edit dropping every minor.
echo "Setting up: php-versions.json .supported is empty array"
echo '{"supported": []}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: empty .supported array fails loud" \
    ci-php-versions-lockstep \
    'missing, empty, or not an array'
restore_worktree

# Unsorted .supported — must NOT fail; the lockstep sorts internally
# before comparing, so operator may store the list in any order.
echo "Setting up: php-versions.json .supported is unsorted but valid"
echo '{"supported": ["8.5", "8.3", "8.4"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_passes \
    "ci-php-versions-lockstep: unsorted but valid .supported passes" \
    ci-php-versions-lockstep
restore_worktree

# Zero-width space inside a value (`"8.3​"`) — `\S` would let
# this through, but the strict X.Y regex `^[1-9][0-9]*\.[0-9]+$`
# rejects. Without this defense, the comparison would print
# "8.3,8.4,8.5" vs "8.3,8.4,8.5" (visually identical, byte-different)
# and burn operator debugging time.
echo "Setting up: php-versions.json .supported has zero-width-space-bearing entry"
printf '{"supported": ["8.3\\u200b", "8.4", "8.5"]}\n' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: zero-width-space in .supported fails loud" \
    ci-php-versions-lockstep \
    'duplicates, non-strings, empty values'
restore_worktree

# Shape-family malformed entries: trailing dot, leading dot, dot-only,
# patch-pinned, no-dot, leading-zero major. The loose `^[0-9.]+$` would
# accept every one of these; the strict X.Y regex rejects all of them.
# Each case is a hand-edit typo that could otherwise propagate via
# check-versions.yml's auto-bump fan-out into every new versions.json
# row, producing `FROM php:8.-fpm-alpine` (invalid reference format).
echo "Setting up: php-versions.json .supported has trailing-dot entry"
echo '{"supported": ["8.", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: trailing-dot value (\`8.\`) fails loud" \
    ci-php-versions-lockstep \
    'not matching the strict X.Y minor shape'
restore_worktree

echo "Setting up: php-versions.json .supported has leading-dot entry"
echo '{"supported": [".3", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: leading-dot value (\`.3\`) fails loud" \
    ci-php-versions-lockstep \
    'not matching the strict X.Y minor shape'
restore_worktree

echo "Setting up: php-versions.json .supported has dot-only entry"
echo '{"supported": ["...", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: dot-only value (\`...\`) fails loud" \
    ci-php-versions-lockstep \
    'not matching the strict X.Y minor shape'
restore_worktree

echo "Setting up: php-versions.json .supported has patch-pinned entry"
echo '{"supported": ["8.3.1", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: patch-pinned value (\`8.3.1\`) fails loud" \
    ci-php-versions-lockstep \
    'not matching the strict X.Y minor shape'
restore_worktree

echo "Setting up: php-versions.json .supported has no-dot entry"
echo '{"supported": ["8", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: no-dot value (\`8\`) fails loud" \
    ci-php-versions-lockstep \
    'not matching the strict X.Y minor shape'
restore_worktree

echo "Setting up: php-versions.json .supported has leading-zero major"
echo '{"supported": ["08.3", "8.4", "8.5"]}' > "$worktree/dev/php-versions.json"
assert_lockstep_fails \
    "ci-php-versions-lockstep: leading-zero major (\`08.3\`) fails loud" \
    ci-php-versions-lockstep \
    'not matching the strict X.Y minor shape'
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
# ci-healthcheck-lockstep — entire start_period line deleted from template
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: installer template nginx start_period line deleted entirely"
# A future refactor that drops the start_period: key altogether (vs the
# blanked-value case above) must still surface as `::error::start_period
# not found`, not a bash-pipefail abort with no annotation. The
# `|| true` after the grep in check-healthcheck-start-period.sh
# preserves the explicit empty-value diagnostic on this path.
sed -i '/^    nginx:/,/^    [a-z]/{/start_period:/d;}' \
    "$worktree/installer/webtrees_installer/templates/compose.standalone.j2"
assert_lockstep_fails \
    "ci-healthcheck-lockstep: deleted start_period line in template fails the lookup" \
    ci-healthcheck-lockstep \
    "start_period not found"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-port-default-lockstep — default port drift in a mirror site
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: docs/env-vars.md APP_PORT default mutated from 28080 to 80"
# docs/env-vars.md is the exact site that drifted historically (see the
# recipe comment) — re-create the regression so the lockstep target
# proves it catches it now.
# shellcheck disable=SC2016  # markdown backticks are literal in the sed pattern
sed -i 's|compose default `28080`|compose default `80`|' \
    "$worktree/docs/env-vars.md"
assert_lockstep_fails \
    "ci-port-default-lockstep: docs/env-vars.md drift surfaces a clear error" \
    ci-port-default-lockstep \
    "docs/env-vars.md(default)"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-port-default-lockstep — fallback port drift in README
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README.md fallback 28081 mutated"
# README is the only site that mentions both the default and the
# fallback port, so it is the canonical fallback mirror.
sed -i 's|28081|99999|g' "$worktree/README.md"
assert_lockstep_fails \
    "ci-port-default-lockstep: README.md fallback drift surfaces a clear error" \
    ci-port-default-lockstep \
    "README.md(fallback)"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-port-default-lockstep — parser fails when _DEFAULT_PORT is missing
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: flow.py _DEFAULT_PORT line stripped"
# Bypass the literal so the parser returns empty and trips its own
# `::error::` annotation rather than silently emitting empty values
# that would then make every mirror site falsely look drift-free.
sed -i 's|^_DEFAULT_PORT = 28080$|# _DEFAULT_PORT removed for test|' \
    "$worktree/installer/webtrees_installer/flow.py"
assert_lockstep_fails \
    "ci-port-default-lockstep: parser fails loud when _DEFAULT_PORT is missing" \
    ci-port-default-lockstep \
    "Could not parse _DEFAULT_PORT"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-port-default-lockstep — parser fails when _FALLBACK_PORT is missing
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: flow.py _FALLBACK_PORT line stripped"
# Parity with the _DEFAULT_PORT case — both error branches in
# scripts/parse-port-defaults.sh must trip on a missing constant.
sed -i 's|^_FALLBACK_PORT = 28081$|# _FALLBACK_PORT removed for test|' \
    "$worktree/installer/webtrees_installer/flow.py"
assert_lockstep_fails \
    "ci-port-default-lockstep: parser fails loud when _FALLBACK_PORT is missing" \
    ci-port-default-lockstep \
    "Could not parse _FALLBACK_PORT"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-port-default-lockstep — default == fallback collapses semantics
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: flow.py _FALLBACK_PORT mutated to equal _DEFAULT_PORT"
# When the two constants share a value, flow.py:_resolve_port's
# `if port == _FALLBACK_PORT` branch silently never fires — the
# wizard would think it has a fallback when it doesn't. The parser
# now asserts they differ.
sed -i 's|^_FALLBACK_PORT = 28081$|_FALLBACK_PORT = 28080|' \
    "$worktree/installer/webtrees_installer/flow.py"
assert_lockstep_fails \
    "ci-port-default-lockstep: parser rejects _DEFAULT_PORT == _FALLBACK_PORT" \
    ci-port-default-lockstep \
    "_DEFAULT_PORT and _FALLBACK_PORT must differ"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — PHP badge missing one of the unique values
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README PHP badge drops one of the unique values (8.3)"
# Strip `8.3%7C` from the PHP badge URL — the unique values from
# versions.json no longer all appear in the static badge, so the lockstep
# must fail loud naming the missing value.
sed -i 's|PHP-8.3%7C8.4%7C8.5-787CB5|PHP-8.4%7C8.5-787CB5|' "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: PHP badge missing a unique value fails" \
    ci-readme-badge-lockstep \
    'PHP badge does not encode'
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
