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
    local name=$1 target=$2 expect_in_stderr=${3:-}
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

    # Optional positive-control assertion on stderr content. Lets a
    # caller distinguish e.g. "exited 0 via short-circuit" from "exited
    # 0 via full execution" — otherwise a regression that renames an
    # env-var guard would silently fall through to the normal happy
    # path and the test would still pass.
    if [ -n "$expect_in_stderr" ] && ! printf '%s\n' "$stderr_out" | grep -qF "$expect_in_stderr"; then
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
    # (e.g. a not-yet-committed scripts/lockstep/parse-alpine-pin.sh).
    #
    # New tests creating untracked artefacts inside $worktree need their
    # own bespoke cleanup — this restore intentionally only handles the
    # tracked-mutation revert.
    git -C "$worktree" checkout HEAD -- . >/dev/null 2>&1
    apply_overlay
}

# Run scripts/lockstep/parse-alpine-pin.sh against an _alpine.py written from
# `fixture_content`, assert it prints `expected_pin` and exits 0.
assert_parser_outputs() {
    local name=$1 fixture_content=$2 expected_pin=$3
    local fixture_file="$worktree/installer/webtrees_installer/_alpine.py"
    local actual exit_code

    printf '%s\n' "$fixture_content" > "$fixture_file"

    set +e
    actual=$(cd "$worktree" && ./scripts/lockstep/parse-alpine-pin.sh 2>/dev/null)
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

# Run scripts/lockstep/parse-alpine-pin.sh against an _alpine.py written from
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
    stderr_out=$(cd "$worktree" && ./scripts/lockstep/parse-alpine-pin.sh 2>&1 >/dev/null)
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
    'webtrees badge does not encode the same set'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — 4-value PHP badge accepted under set-equality
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json grows PHP 8.10; README badge encodes all four values"
# Adds a row with PHP 8.10 (and an existing webtrees value so the
# webtrees badge stays satisfied). The set-equality recipe accepts
# any order, so this fixture exercises a 4-value badge end-to-end and
# pins that adding a 2-digit minor doesn't break the recipe's URL
# parsing or set comparison. Natural-sort ordering itself is pinned
# by installer/tests/test_rewrite_readme_badges.py — the recipe is
# order-independent by design, so the lockstep cannot validate sort
# order.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"2.2.6","php":"8.10","tags":[]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
sed -i 's|PHP-8.3%7C8.4%7C8.5-787CB5|PHP-8.3%7C8.4%7C8.5%7C8.10-787CB5|' "$worktree/README.md"
assert_lockstep_passes \
    "ci-readme-badge-lockstep: 4-value PHP badge accepted (set-equality)" \
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
    'webtrees badge does not encode the same set'
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
    'webtrees badge does not encode the same set'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — duplicate value within a single badge URL
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README webtrees badge encodes 2.1.27 twice (hand-edit/merge artefact)"
# Hand-edit / merge-conflict resolution could leave a duplicate value
# in the badge URL: `webtrees-2.1.27%7C2.2.6%7C2.1.27-blue`. A naive
# `sort -u | comm` would silently accept this because the SET still
# matches versions.json. The lockstep must reject duplicate values
# WITHIN a single badge URL so the rendered badge cannot ship as
# `2.1.27 | 2.2.6 | 2.1.27` to readers.
sed -i 's|webtrees-2.1.27%7C2.2.6-blue|webtrees-2.1.27%7C2.2.6%7C2.1.27-blue|' "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: duplicate value in single badge URL rejected" \
    ci-readme-badge-lockstep \
    'duplicate values'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — second webtrees badge with stale value
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README carries a second webtrees-...-blue URL out of sync with versions.json"
# The rewriter uses `re.subn` (replaces every match), so the checker
# must scan ALL matching badge URLs and aggregate their values into a
# single union set. A second context-specific badge (changelog / docs
# example / archived screenshot caption) whose union diverges from
# versions.json must fail the lockstep loud so the divergence cannot
# slip through as a green-CI no-op when the canonical badge alone
# still matches the catalog.
printf '\nLegacy badge example: ![old](https://img.shields.io/badge/webtrees-1.7.0-blue)\n' >> "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: second webtrees badge with extra value rejected" \
    ci-readme-badge-lockstep \
    'webtrees badge does not encode the same set'
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
# ci-readme-badge-lockstep — unparseable JSON in versions.json
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json is not valid JSON"
# A truncated / hand-mangled versions.json must surface as an
# actionable annotation rather than a generic `docker run failed`.
# The recipe's first guard runs `jq empty versions.json` and must
# trip on syntactic garbage.
echo 'not-json-at-all' > "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: unparseable versions.json fails with actionable message" \
    ci-readme-badge-lockstep \
    'is not parseable JSON'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — trailing-whitespace in versions.json value
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: dev/versions.json row carries a trailing-space php value"
# A hand-edit / paste accident leaves `"php":"8.5 "` (trailing space)
# in the catalog. The Python rewriter strips whitespace before
# writing to README; the jq lockstep must mirror that strip so the
# expected set matches the rewriter's canonical output. Without the
# alignment, expected_php would carry `"8.5 "` while actual would
# carry `"8.5"`, deadlocking the lockstep on a character-identical
# visual diff that's hours to debug.
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    -c '. + [{"webtrees":"2.2.6","php":"8.5 ","tags":[]}]' versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_passes \
    "ci-readme-badge-lockstep: trailing-whitespace php value strip-aligned with rewriter" \
    ci-readme-badge-lockstep
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — README missing the webtrees badge URL entirely
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README has no webtrees-...-blue URL at all"
# If the webtrees badge URL is removed from README (e.g. accidental
# delete during a docs sweep), the recipe must fail loud with the
# `no img.shields.io/badge/webtrees-...-blue URL found` annotation,
# not a confusing set-equality diff.
sed -i '/img\.shields\.io\/badge\/webtrees/d' "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: README without webtrees badge URL fails loud" \
    ci-readme-badge-lockstep \
    'no img.shields.io/badge/webtrees-...-blue URL found'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-readme-badge-lockstep — README missing the PHP badge URL entirely
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: README has no PHP-...-787CB5 URL at all"
# Symmetric to the webtrees case above: deleting the PHP badge URL
# entirely must surface the dedicated `no img.shields.io/badge/PHP-
# ...-787CB5 URL found` annotation rather than degrading to a
# set-equality diff against an empty actual set.
sed -i '/img\.shields\.io\/badge\/PHP/d' "$worktree/README.md"
assert_lockstep_fails \
    "ci-readme-badge-lockstep: README without PHP badge URL fails loud" \
    ci-readme-badge-lockstep \
    'no img.shields.io/badge/PHP-...-787CB5 URL found'
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
#
# Issue #141: the installer templates now consume a shared
# `nginx_healthcheck()` macro from `_compose_macros.j2`. Drift fixtures
# that previously mutated the template's inline `start_period:` now
# target the macro file via mutate_nginx_macro_start_period.
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

# Counterpart for the shared installer-side macro. Walks from the
# `nginx_healthcheck` macro header to its `endmacro` terminator and
# replaces the start_period literal — the macro file carries one
# start_period that BOTH rendered templates inherit.
mutate_nginx_macro_start_period() {
    local file=$1 new_value=$2
    local before_hash after_hash
    before_hash=$(md5sum "$file" | awk '{print $1}')
    # Same anchored sed range the production lockstep uses
    # (`{%- macro nginx_healthcheck(` … `{%- endmacro -%}`) so a
    # stray comment containing the substring `macro nginx_healthcheck`
    # cannot shift either surface's range.
    sed -i "/{%- macro nginx_healthcheck(/,/{%- endmacro -%}/{s|\\(start_period:\\) [0-9]*s|\\1 ${new_value}|;}" "$file"
    after_hash=$(md5sum "$file" | awk '{print $1}')
    if [ "$before_hash" = "$after_hash" ]; then
        echo "FAIL: mutate_nginx_macro_start_period made no change to $file" \
             "— nginx_healthcheck macro may have moved or the value left the [0-9]+s shape"
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
# ci-healthcheck-lockstep — macro-side drift (both rendered templates
# inherit the same start_period, so a single mutation covers both)
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: _compose_macros.j2 nginx start_period mutated to 99s"
mutate_nginx_macro_start_period \
    "$worktree/installer/webtrees_installer/templates/_compose_macros.j2" "99s"
assert_lockstep_fails \
    "ci-healthcheck-lockstep: installer macro drift surfaces a clear error" \
    ci-healthcheck-lockstep \
    "start_period drift"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-healthcheck-lockstep — start_period missing entirely on one side
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: installer macro nginx start_period blanked"
# Blank the value (keep the key) so the file shape stays parseable and
# the failure is "not found", not a Jinja syntax error.
mutate_nginx_macro_start_period \
    "$worktree/installer/webtrees_installer/templates/_compose_macros.j2" ""
assert_lockstep_fails \
    "ci-healthcheck-lockstep: blank start_period in macro fails the lookup" \
    ci-healthcheck-lockstep \
    "start_period not found"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-healthcheck-lockstep — entire start_period line deleted from macro
# ──────────────────────────────────────────────────────────────────────
echo "Setting up: installer macro nginx start_period line deleted entirely"
# A future refactor that drops the start_period: key altogether (vs the
# blanked-value case above) must still surface as `::error::start_period
# not found`, not a bash-pipefail abort with no annotation.
sed -i '/{%- macro nginx_healthcheck(/,/{%- endmacro -%}/{/start_period:/d;}' \
    "$worktree/installer/webtrees_installer/templates/_compose_macros.j2"
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
# scripts/lockstep/parse-port-defaults.sh must trip on a missing constant.
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
    'PHP badge does not encode the same set'
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# scripts/lockstep/parse-alpine-pin.sh — happy-path variants
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
# scripts/lockstep/parse-alpine-pin.sh — parse-failure path
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
# ci-tls-verify-lockstep (issue #128)
# ──────────────────────────────────────────────────────────────────────

# Inject a representative TLS bypass into a real executable file and
# assert the lockstep flags it. scripts/build/install-application.sh is
# chosen as the injection target because it already shells out — a
# bypass landing there in a real refactor is the exact scenario the
# lockstep guards against.
echo "Setting up: inject 'curl --insecure' into scripts/build/install-application.sh"
printf '\n# pretend bypass injected by ci-tls-verify-lockstep failure-path test\ncurl --insecure https://example.com\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: curl --insecure flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# verify=False (Python requests / urllib3 idiom).
echo "Setting up: inject 'verify=False' into a Python module"
printf '\n# pretend bypass\n_resp = requests.get("https://example.com", verify=False)\n' \
    >> "$worktree/installer/webtrees_installer/_progress.py"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: verify=False flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# composer secure-http false.
echo "Setting up: inject 'composer config secure-http false'"
printf '\n# pretend bypass\ncomposer config secure-http false\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: composer secure-http false flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# curl short alias `-k` (and combined flags like -kfsSL). The short
# form is what hand-typed troubleshooting most often produces.
echo "Setting up: inject 'curl -kfsSL' combined-flags form"
printf '\n# pretend bypass\ncurl -kfsSL https://example.com\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: curl -kfsSL combined-flags flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# git -c http.sslVerify=false (the form git docs treat as equivalent
# to GIT_SSL_NO_VERIFY=1).
echo "Setting up: inject 'git -c http.sslVerify=false'"
printf '\n# pretend bypass\ngit -c http.sslVerify=false clone https://example.com\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: http.sslVerify=false flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# Node.js env-var bypass (workflows that publish to npm registries
# under self-signed CAs occasionally reach for this).
echo "Setting up: inject 'NODE_TLS_REJECT_UNAUTHORIZED=0'"
printf '\nNODE_TLS_REJECT_UNAUTHORIZED=0\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: NODE_TLS_REJECT_UNAUTHORIZED=0 flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# YAML/JSON-quoted form: `args: ["--insecure"]`. The boundary set
# must accept `"` adjacent to the flag.
echo "Setting up: inject YAML-quoted '--insecure' in a workflow"
printf '\n# pretend workflow step\nargs: ["--insecure"]\n' \
    >> "$worktree/.github/workflows/build.yml"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: YAML-quoted --insecure flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# Shell statement-separator boundary: `curl -k;next` or
# `curl --insecure|tee` must flag. A scripting habit of compressing
# one-liners is the realistic regression vector.
echo "Setting up: inject 'curl -k;next' shell-separator form"
printf '\n# pretend bypass\ncurl -k;tee /tmp/x\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_fails \
    "ci-tls-verify-lockstep: curl -k;next (semicolon boundary) flagged" \
    "ci-tls-verify-lockstep" \
    "TLS-verify bypass detected"
restore_worktree

# Negative control: near-miss strings (`--insecure-flag-help`,
# `verify_email_address`, `fsSL` without `-k`) must NOT flag. Catches
# a future regex broadening that drops the boundary anchor.
echo "Setting up: inject near-miss strings that must NOT flag"
printf '\n# Documentation: handles --insecure-related corner cases\nverify_email_address = True\ncurl -fsSL https://example.com\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_passes \
    "ci-tls-verify-lockstep: near-miss strings pass cleanly" \
    "ci-tls-verify-lockstep"
restore_worktree

# Negative control: word-boundary on `\bcurl`. `mycurl -k` /
# `_curl -k` / `xcurl -k` must NOT flag — they are not invocations of
# curl, only identifier substrings.
echo "Setting up: inject 'mycurl -k' word-boundary near-miss"
printf '\n# pretend a wrapper script is named mycurl\nmycurl -k https://example.com\nxcurl -kfsSL https://example.com\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_passes \
    "ci-tls-verify-lockstep: mycurl/xcurl prefix-substring passes cleanly" \
    "ci-tls-verify-lockstep"
restore_worktree

# Negative control: `curl -K config.txt` (curl's --config short alias,
# uppercase K) must NOT flag — the deny-pattern requires lowercase k.
echo "Setting up: inject 'curl -K' (curl --config uppercase alias)"
printf '\ncurl -K /tmp/curl.config\ncurl -K config.txt https://example.com\n' \
    >> "$worktree/scripts/build/install-application.sh"
assert_lockstep_passes \
    "ci-tls-verify-lockstep: curl -K (uppercase, --config alias) passes" \
    "ci-tls-verify-lockstep"
restore_worktree

# Positive control: HEAD's lockstep state passes cleanly with no
# injection. Catches a future deny-list overhaul that accidentally
# matches the unchanged executable corpus.
assert_lockstep_passes \
    "ci-tls-verify-lockstep: clean tree passes" \
    "ci-tls-verify-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-diy-env-vars-lockstep (issue #126)
# ──────────────────────────────────────────────────────────────────────

# Inject a bogus env-var name into docs/diy.md and assert the
# lockstep flags it as missing from docs/env-vars.md. Picks
# `WEBTREES_BOGUS_VAR` because it follows the screaming-snake
# convention the deny-regex matches and clearly does not exist in
# the authoritative table.
echo "Setting up: inject 'WEBTREES_BOGUS_VAR' into docs/diy.md"
# Backticks inside the single-quoted printf are intentional markdown
# inline-code delimiters that the lockstep regex matches on.
# shellcheck disable=SC2016
printf '\nA new optional knob: `WEBTREES_BOGUS_VAR` (not real).\n' \
    >> "$worktree/docs/diy.md"
assert_lockstep_fails \
    "ci-diy-env-vars-lockstep: undocumented var flagged" \
    "ci-diy-env-vars-lockstep" \
    "WEBTREES_BOGUS_VAR"
restore_worktree

# Positive control: clean tree passes (catches a future regex
# weakening that drops all matches).
assert_lockstep_passes \
    "ci-diy-env-vars-lockstep: clean tree passes" \
    "ci-diy-env-vars-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-nginx-tag-derivation-lockstep
# ──────────────────────────────────────────────────────────────────────

echo "Setting up: nginx-version.json .config_revision bumped, .tag stale"
echo '{"nginx_base": "1.30", "config_revision": 2, "tag": "1.30-r1"}' \
    > "$worktree/dev/nginx-version.json"
assert_lockstep_fails \
    "ci-nginx-tag-derivation-lockstep: tag drift from config_revision bump" \
    "ci-nginx-tag-derivation-lockstep" \
    "have '1.30-r1', expected '1.30-r2'"
restore_worktree

echo "Setting up: nginx-version.json missing .tag"
echo '{"nginx_base": "1.30", "config_revision": 1}' \
    > "$worktree/dev/nginx-version.json"
assert_lockstep_fails \
    "ci-nginx-tag-derivation-lockstep: missing .tag field flagged" \
    "ci-nginx-tag-derivation-lockstep" \
    "missing required field 'tag'"
restore_worktree

assert_lockstep_passes \
    "ci-nginx-tag-derivation-lockstep: clean tree passes" \
    "ci-nginx-tag-derivation-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-php-digests-lockstep
# ──────────────────────────────────────────────────────────────────────

echo "Setting up: php_digests.lock missing 8.3 line"
grep -v '^8\.3=' "$worktree/dev/php_digests.lock" > "$worktree/dev/php_digests.lock.new"
mv "$worktree/dev/php_digests.lock.new" "$worktree/dev/php_digests.lock"
assert_lockstep_fails \
    "ci-php-digests-lockstep: missing supported minor flagged" \
    "ci-php-digests-lockstep" \
    "key set drift"
restore_worktree

echo "Setting up: php_digests.lock contains garbled line"
{
    echo '8.3=sha256:notahexvalue'
    echo '8.4=sha256:2e8d5b74437b02cbc3c632903d20a10fdcc956ba56d25bff951cc2b610767c9a'
    echo '8.5=sha256:82dd8cfd2aa93a98b0357e4c810f894c4ca265b5034aef3be654faae5f579487'
} > "$worktree/dev/php_digests.lock"
assert_lockstep_fails \
    "ci-php-digests-lockstep: malformed line shape flagged" \
    "ci-php-digests-lockstep" \
    "malformed line"
restore_worktree

assert_lockstep_passes \
    "ci-php-digests-lockstep: clean tree passes" \
    "ci-php-digests-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-versions-latest-semver-max-lockstep
# ──────────────────────────────────────────────────────────────────────

echo "Setting up: versions.json 'latest' tag moved off the semver-max row"
# shellcheck disable=SC2016
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    '(.[0].tags) |= map(select(. != "latest")) | (.[3].tags) |= (. + ["latest"])' \
    versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-versions-latest-semver-max-lockstep: 'latest' on non-max row flagged" \
    "ci-versions-latest-semver-max-lockstep" \
    "'latest' tag is on webtrees"
restore_worktree

echo "Setting up: versions.json 'latest' tag duplicated across two rows (different webtrees)"
# shellcheck disable=SC2016
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    '(.[3].tags) |= (. + ["latest"])' \
    versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-versions-latest-semver-max-lockstep: multiple 'latest' rows flagged (diff webtrees)" \
    "ci-versions-latest-semver-max-lockstep" \
    "2 rows with the 'latest' tag"
restore_worktree

# Same-webtrees duplicate: two rows with identical webtrees value, both
# carrying `latest`. A weaker check that `unique`s on .webtrees would
# silently collapse this to one and pass.
echo "Setting up: versions.json 'latest' tag on two rows with same webtrees (different PHP)"
# shellcheck disable=SC2016
docker run --rm -v "$worktree/dev:/d" -w /d ghcr.io/jqlang/jq:latest \
    '(.[1].tags) |= (. + ["latest"])' \
    versions.json > "$worktree/dev/versions.json.new"
mv "$worktree/dev/versions.json.new" "$worktree/dev/versions.json"
assert_lockstep_fails \
    "ci-versions-latest-semver-max-lockstep: multiple 'latest' rows flagged (same webtrees)" \
    "ci-versions-latest-semver-max-lockstep" \
    "2 rows with the 'latest' tag"
restore_worktree

assert_lockstep_passes \
    "ci-versions-latest-semver-max-lockstep: clean tree passes" \
    "ci-versions-latest-semver-max-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-env-dist-pins-lockstep
# ──────────────────────────────────────────────────────────────────────

# Mirrors the live-demonstrated regression where .env.dist's nginx pin
# fell behind dev/nginx-version.json after a bump.
echo "Setting up: .env.dist WEBTREES_NGINX_VERSION holds a stale tag"
sed -i 's/^WEBTREES_NGINX_VERSION=.*/WEBTREES_NGINX_VERSION=1.28-r1/' "$worktree/.env.dist"
assert_lockstep_fails \
    "ci-env-dist-pins-lockstep: stale WEBTREES_NGINX_VERSION flagged" \
    "ci-env-dist-pins-lockstep" \
    "WEBTREES_NGINX_VERSION drift"
restore_worktree

echo "Setting up: .env.dist WEBTREES_VERSION holds a stale value"
sed -i 's/^WEBTREES_VERSION=.*/WEBTREES_VERSION=2.1.27/' "$worktree/.env.dist"
assert_lockstep_fails \
    "ci-env-dist-pins-lockstep: stale WEBTREES_VERSION flagged" \
    "ci-env-dist-pins-lockstep" \
    "WEBTREES_VERSION drift"
restore_worktree

echo "Setting up: .env.dist missing NGINX_CONFIG_REVISION"
grep -v '^NGINX_CONFIG_REVISION=' "$worktree/.env.dist" > "$worktree/.env.dist.new"
mv "$worktree/.env.dist.new" "$worktree/.env.dist"
assert_lockstep_fails \
    "ci-env-dist-pins-lockstep: missing NGINX_CONFIG_REVISION flagged" \
    "ci-env-dist-pins-lockstep" \
    "missing required key 'NGINX_CONFIG_REVISION'"
restore_worktree

# PHP_VERSION drift: .env.dist's pin must be in .supported.
echo "Setting up: .env.dist PHP_VERSION holds a minor outside .supported"
sed -i 's/^PHP_VERSION=.*/PHP_VERSION=8.0/' "$worktree/.env.dist"
assert_lockstep_fails \
    "ci-env-dist-pins-lockstep: PHP_VERSION outside .supported flagged" \
    "ci-env-dist-pins-lockstep" \
    "PHP_VERSION drift"
restore_worktree

# NGINX_BASE drift: .env.dist's pin must mirror dev/nginx-version.json .nginx_base.
echo "Setting up: .env.dist NGINX_BASE holds a stale value"
sed -i 's/^NGINX_BASE=.*/NGINX_BASE=1.28/' "$worktree/.env.dist"
assert_lockstep_fails \
    "ci-env-dist-pins-lockstep: stale NGINX_BASE flagged" \
    "ci-env-dist-pins-lockstep" \
    "NGINX_BASE drift"
restore_worktree

# Duplicate-key trap: docker compose treats the LAST KEY= line as
# authoritative; a stale leftover above would silently flip the
# effective value. Refuse ambiguity instead.
echo "Setting up: .env.dist defines WEBTREES_VERSION twice"
printf '\nWEBTREES_VERSION=9.9.9\n' >> "$worktree/.env.dist"
assert_lockstep_fails \
    "ci-env-dist-pins-lockstep: duplicate WEBTREES_VERSION flagged" \
    "ci-env-dist-pins-lockstep" \
    "defines 'WEBTREES_VERSION' 2 times"
restore_worktree

assert_lockstep_passes \
    "ci-env-dist-pins-lockstep: clean tree passes" \
    "ci-env-dist-pins-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-dockerfile-arg-defaults-lockstep
# ──────────────────────────────────────────────────────────────────────

# mutate_dockerfile_arg helps protect this section against silent sed
# no-ops: if a future PHP/nginx bump rolls the Dockerfile default past
# our hard-coded fixture value, sed exits 0 with zero modifications and
# the lockstep then runs against an unmutated tree, producing a
# confusing 'expected non-zero exit, got 0' diagnostic far from the
# real cause. The hash-before/hash-after guard fails the test at the
# fixture step, naming the file the maintainer has to refresh.
mutate_dockerfile_arg() {
    local file=$1 key=$2 new_value=$3
    local before after
    before=$(md5sum "$file")
    # Replace EVERY occurrence so the multi-site invariant of the
    # check-dockerfile-arg-defaults.sh script is exercised.
    sed -i -E "s|^ARG ${key}=.*\$|ARG ${key}=${new_value}|" "$file"
    after=$(md5sum "$file")
    if [ "$before" = "$after" ]; then
        echo "FAIL: mutate_dockerfile_arg made no change to $file — ARG ${key}= default may have rolled past the hard-coded pattern"
        return 1
    fi
}

echo "Setting up: Dockerfile carries a stale ARG PHP_VERSION default"
mutate_dockerfile_arg "$worktree/Dockerfile" PHP_VERSION 8.2
assert_lockstep_fails \
    "ci-dockerfile-arg-defaults-lockstep: stale PHP_VERSION default flagged" \
    "ci-dockerfile-arg-defaults-lockstep" \
    "ARG PHP_VERSION=8.2"
restore_worktree

echo "Setting up: Dockerfile carries an inconsistent NGINX_BASE default"
mutate_dockerfile_arg "$worktree/Dockerfile" NGINX_BASE 1.29
assert_lockstep_fails \
    "ci-dockerfile-arg-defaults-lockstep: stale NGINX_BASE default flagged" \
    "ci-dockerfile-arg-defaults-lockstep" \
    "ARG NGINX_BASE=1.29"
restore_worktree

echo "Setting up: Dockerfile carries an inconsistent WEBTREES_VERSION default"
mutate_dockerfile_arg "$worktree/Dockerfile" WEBTREES_VERSION 2.2.5
assert_lockstep_fails \
    "ci-dockerfile-arg-defaults-lockstep: stale WEBTREES_VERSION default flagged" \
    "ci-dockerfile-arg-defaults-lockstep" \
    "ARG WEBTREES_VERSION=2.2.5"
restore_worktree

assert_lockstep_passes \
    "ci-dockerfile-arg-defaults-lockstep: clean tree passes" \
    "ci-dockerfile-arg-defaults-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-composer-patches-lockstep
# ──────────────────────────────────────────────────────────────────────

# Drift: composer-core-2.2.json gets an extra patch entry that the matching
# composer-full-2.2.json doesn't carry. The lockstep must flag the asymmetry.
echo "Setting up: composer-core-2.2.json gains an extra patch entry not in composer-full-2.2.json"
# shellcheck disable=SC2016
docker run --rm -v "$worktree/setup:/d" -w /d ghcr.io/jqlang/jq:latest \
    '.extra.patches["fisharebest/webtrees"]["Bogus extra patch"] = "patches/bogus.patch"' \
    composer-core-2.2.json > "$worktree/setup/composer-core-2.2.json.new"
mv "$worktree/setup/composer-core-2.2.json.new" "$worktree/setup/composer-core-2.2.json"
assert_lockstep_fails \
    "ci-composer-patches-lockstep: extra patch only in core flagged" \
    "ci-composer-patches-lockstep" \
    "divergent extra.patches"
restore_worktree

# Drift: composer-core-2.1.json gets an unexpected description.
# Anything outside the documented-divergence keys must be byte-identical.
echo "Setting up: composer-core-2.1.json gets an unexpected sort-packages flip"
# shellcheck disable=SC2016
docker run --rm -v "$worktree/setup:/d" -w /d ghcr.io/jqlang/jq:latest \
    '.config["sort-packages"] = false' \
    composer-core-2.1.json > "$worktree/setup/composer-core-2.1.json.new"
mv "$worktree/setup/composer-core-2.1.json.new" "$worktree/setup/composer-core-2.1.json"
assert_lockstep_fails \
    "ci-composer-patches-lockstep: unexpected divergence outside documented set flagged" \
    "ci-composer-patches-lockstep" \
    "diverges from the manifest baseline"
restore_worktree

assert_lockstep_passes \
    "ci-composer-patches-lockstep: clean tree passes" \
    "ci-composer-patches-lockstep"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-patches-apply-lockstep
# ──────────────────────────────────────────────────────────────────────

assert_lockstep_passes \
    "ci-patches-apply-lockstep: clean tree passes (online apply check)" \
    "ci-patches-apply-lockstep"
restore_worktree

# Mutate disable-upgrade-prompt.patch so the context anchor no longer
# matches; the apply check must reject.
echo "Setting up: disable-upgrade-prompt.patch has a broken context line"
sed -i 's/public function isUpgradeAvailable/public function isUpgradeNotAvailable/' \
    "$worktree/setup/patches/disable-upgrade-prompt.patch"
assert_lockstep_fails \
    "ci-patches-apply-lockstep: broken context anchor flagged" \
    "ci-patches-apply-lockstep" \
    "does not apply cleanly"
restore_worktree

# ──────────────────────────────────────────────────────────────────────
# ci-portainer-templates-lockstep
# ──────────────────────────────────────────────────────────────────────
#
# The render-path tests (mutated-drift + clean-pass) are intentionally
# omitted here. Each case invokes the full renderer (docker run
# python:3.13-slim + pip install + jinja render, ~60–90 s) and two
# cases push the overall test-lockstep wall-clock past the harness
# budget (observed Exit 137 = SIGKILL). The lockstep itself runs every
# CI invocation via `ci-test`, so actual drift between committed
# templates/portainer/ files and the Jinja sources fails CI loudly.
#
# What IS exercised here: the CHECK_PORTAINER_TEMPLATES=0 offline
# escape hatch. It short-circuits before any docker invocation
# (~10 ms), and a regression that renames the env var, flips the
# default, or moves the guard below the docker block would break
# offline CI lanes silently. That branch has no production gate, so
# this cheap test pins the contract in place.

CHECK_PORTAINER_TEMPLATES=0 assert_lockstep_passes \
    "ci-portainer-templates-lockstep: CHECK_PORTAINER_TEMPLATES=0 short-circuits" \
    "ci-portainer-templates-lockstep" \
    "CHECK_PORTAINER_TEMPLATES=0 — skipping portainer-templates lockstep"
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
