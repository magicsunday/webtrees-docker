#!/usr/bin/env bash
#
# Integration tests for rootfs/docker-entrypoint.sh — specifically the
# setup_webtrees_dist state machine that seeds /var/www/html on first run.
#
# Each test sets up controlled volume state inside an ephemeral docker
# volume, runs the entrypoint, and asserts on exit code + log output.
#
# Usage:
#   ./tests/test-entrypoint.sh                              # uses default image
#   TEST_IMAGE=ghcr.io/magicsunday/webtrees/php:8.5 ./tests/test-entrypoint.sh
#
# Exit codes:
#   0  all tests passed
#   1  at least one test failed

set -o errexit -o nounset -o pipefail

IMAGE="${TEST_IMAGE:-ghcr.io/magicsunday/webtrees/php:8.5}"

# Source-tree entrypoint, bind-mounted only by tests that exercise
# behaviour not yet baked into the published image. Once the change
# under test ships in a tagged image, the matching test can drop the
# overlay and join the rest of the suite running against the published
# entrypoint as-is.
ENTRYPOINT_SRC="$(cd "$(dirname "$0")/.." && pwd)/rootfs/docker-entrypoint.sh"

# Env vars setup_php needs to find — keeps the test focused on the seed
# state machine rather than tripping over unrelated configuration paths.
PHP_ENV=(
    -e PHP_MAX_EXECUTION_TIME=30
    -e PHP_MAX_INPUT_VARS=1000
    -e PHP_MEMORY_LIMIT=128M
)

pass=0
fail=0
results=()

# Track every named volume we create so the EXIT trap can sweep stragglers
# even when a test fails before its explicit vol_rm.
TRACKED_VOLS=()

cleanup_volumes() {
    local v
    for v in "${TRACKED_VOLS[@]}"; do
        docker volume rm "$v" >/dev/null 2>&1 || true
    done
}
trap cleanup_volumes EXIT

# Create an empty named volume and echo its name. Records the new volume in
# TRACKED_VOLS so the EXIT trap can clean up even when an assertion failure
# short-circuits the explicit vol_rm.
mk_vol() {
    local v
    v=$(docker volume create) || return 1
    [[ -n "$v" ]] || return 1
    TRACKED_VOLS+=("$v")
    printf '%s\n' "$v"
}

# Record an mk_vol failure as a test failure and return non-zero so the
# caller can short-circuit. Used as `vol=$(mk_vol) || vol_create_failed "$name" || return`.
vol_create_failed() {
    results+=("FAIL  $1 — docker volume create returned non-zero or empty name")
    fail=$((fail + 1))
    return 1
}

# Run a shell command inside a fresh container with the volume bind-mounted
# at /v, bypassing the image entrypoint (so we can prepare state without
# triggering the entrypoint logic under test).
vol_prep() {
    local vol="$1" cmd="$2"
    docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" -c "$cmd" >/dev/null
}

vol_rm() {
    docker volume rm "$1" >/dev/null 2>&1 || true
}

# Run the entrypoint inside a container and capture exit + output.
# Args:
#   $1 — test name
#   $2 — extra args (space-separated string, e.g. "-v vol:/var/www -e WEBTREES_AUTO_SEED=true")
#   $3 — expected exit code
#   $4 — required output pattern (extended regex), or empty to skip output check
#   $5 — forbidden output pattern, or empty to skip
run_entrypoint_test() {
    local name="$1" extra="$2" want_exit="$3" want_pat="$4" forbid_pat="$5"
    local actual_exit actual_output

    set +e
    # shellcheck disable=SC2086  # intentional word-split on $extra
    actual_output=$(docker run --rm --entrypoint=/bin/bash $extra "${PHP_ENV[@]}" "$IMAGE" -c '/docker-entrypoint.sh true' 2>&1)
    actual_exit=$?
    set -e

    if [[ "$actual_exit" != "$want_exit" ]]; then
        results+=("FAIL  $name — exit $actual_exit, want $want_exit")
        results+=("      output:")
        while IFS= read -r line; do
            results+=("        $line")
        done <<<"$actual_output"
        fail=$((fail + 1))
        return
    fi

    if [[ -n "$want_pat" ]] && ! grep -qE "$want_pat" <<<"$actual_output"; then
        results+=("FAIL  $name — output missing /$want_pat/")
        results+=("      got: $(head -3 <<<"$actual_output" | tr '\n' '|')")
        fail=$((fail + 1))
        return
    fi

    if [[ -n "$forbid_pat" ]] && grep -qE "$forbid_pat" <<<"$actual_output"; then
        results+=("FAIL  $name — output unexpectedly contains /$forbid_pat/")
        fail=$((fail + 1))
        return
    fi

    results+=("PASS  $name")
    pass=$((pass + 1))
}

# Helper: read a path from a volume, echo its content.
vol_cat() {
    local vol="$1" path="$2"
    docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" -c "cat /v/$path 2>/dev/null || true"
}

# Build an ephemeral image with a php stub that records argv and exits 0.
# Used by bootstrap-hook tests to exercise the entrypoint's decision logic
# without needing a real DB connection.
build_stub_image() {
    local stub_image="webtrees-bootstrap-stub:test"

    # Use a heredoc'd Dockerfile via `docker build -`. The image is identical
    # to $IMAGE except /usr/local/bin/php logs args to /var/www/html/.bootstrap-stub.log
    # (inside the volume mount point so tests can inspect via vol_cat) and
    # returns 0.
    docker build -t "$stub_image" --build-arg "BASE_IMAGE=$IMAGE" - >/dev/null <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN if [ -f /usr/local/bin/php ]; then mv /usr/local/bin/php /usr/local/bin/php.real; fi && \
    printf '%s\n' \
        '#!/bin/sh' \
        'echo "PHP-STUB $*" >> /var/www/html/.bootstrap-stub.log 2>/dev/null || true' \
        'exit 0' \
        > /usr/local/bin/php && \
    chmod +x /usr/local/bin/php
EOF
    printf '%s' "$stub_image"
}

#
# State 1: AUTO_SEED unset → skip
#
test_state_1_auto_seed_unset() {
    run_entrypoint_test \
        "state 1: AUTO_SEED unset → skip" \
        "--tmpfs /var/www:exec,uid=82,gid=82" \
        0 \
        "" \
        "Seeding|unmarked|differs"
}

#
# State 2: AUTO_SEED=true + WEBTREES_VERSION empty → fail fast
#
test_state_2_version_empty() {
    run_entrypoint_test \
        "state 2: AUTO_SEED=true + WEBTREES_VERSION empty → fail fast" \
        "--tmpfs /var/www:exec,uid=82,gid=82 -e WEBTREES_AUTO_SEED=true" \
        1 \
        "WEBTREES_VERSION is empty" \
        ""
}

#
# State 3: AUTO_SEED=true + WEBTREES_VERSION set + empty volume → seed
#
test_state_3_seed_fresh() {
    local vol; vol=$(mk_vol) || { vol_create_failed "${FUNCNAME[0]}"; return; }
    run_entrypoint_test \
        "state 3: AUTO_SEED=true + empty volume → seed" \
        "-v $vol:/var/www/html -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6" \
        0 \
        "Seeding /var/www/html" \
        ""

    local marker_content; marker_content=$(vol_cat "$vol" ".webtrees-bundled-version")
    if [[ "$marker_content" != "2.2.6" ]]; then
        results+=("FAIL  state 3 (marker check): want '2.2.6', got '$marker_content'")
        fail=$((fail + 1))
    fi

    # The marker is only meaningful if the seed actually populated the tree.
    # Bootstrap wrapper at /var/www/html/public/index.php is tiny so we only
    # require it to exist, not a minimum size.
    local index_size; index_size=$(vol_cat "$vol" "public/index.php" | wc -c)
    if [[ "$index_size" -lt 50 ]]; then
        results+=("FAIL  state 3 (tree check): /var/www/html/public/index.php is missing or empty ($index_size bytes)")
        fail=$((fail + 1))
    fi

    # Composer-installed webtrees must live under vendor/fisharebest/webtrees/.
    if ! docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" -c 'test -d /v/vendor/fisharebest/webtrees'; then
        results+=("FAIL  state 3 (vendor check): vendor/fisharebest/webtrees/ missing in seeded volume")
        fail=$((fail + 1))
    fi
    vol_rm "$vol"
}

#
# State 4: marker matches + tree intact → skip
#
test_state_4_marker_matches() {
    local vol; vol=$(mk_vol) || { vol_create_failed "${FUNCNAME[0]}"; return; }
    vol_prep "$vol" 'mkdir -p /v/public && cp -a /opt/webtrees-dist/html/public/. /v/public/ && echo 2.2.6 > /v/.webtrees-bundled-version'
    run_entrypoint_test \
        "state 4: marker matches + tree intact → skip" \
        "-v $vol:/var/www/html -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6" \
        0 \
        "" \
        "Seeding|unmarked|differs|missing"
    vol_rm "$vol"
}

#
# State 5: marker absent + tree present (unmarked install) → warn, no clobber
#
test_state_5_unmarked_tree() {
    local vol; vol=$(mk_vol) || { vol_create_failed "${FUNCNAME[0]}"; return; }
    vol_prep "$vol" 'mkdir -p /v/public && echo USERDATA > /v/public/index.php'
    run_entrypoint_test \
        "state 5: marker absent + tree present → warn, no clobber" \
        "-v $vol:/var/www/html -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6" \
        0 \
        "unmarked webtrees install" \
        "Seeding"

    local preserved; preserved=$(vol_cat "$vol" "public/index.php")
    if [[ "$preserved" != "USERDATA" ]]; then
        results+=("FAIL  state 5 (no-clobber): index.php content changed from USERDATA to '$preserved'")
        fail=$((fail + 1))
    fi
    vol_rm "$vol"
}

#
# State 6: marker mismatch + tree intact → warn, no overwrite, exit 0
#
test_state_6_version_mismatch() {
    local vol; vol=$(mk_vol) || { vol_create_failed "${FUNCNAME[0]}"; return; }
    vol_prep "$vol" 'mkdir -p /v/public && cp -a /opt/webtrees-dist/html/public/. /v/public/ && echo 2.2.5 > /v/.webtrees-bundled-version'
    run_entrypoint_test \
        "state 6: marker mismatch + tree intact → warn, exit 0" \
        "-v $vol:/var/www/html -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6" \
        0 \
        "differs from installed 2.2.5" \
        "Seeding"

    local preserved; preserved=$(vol_cat "$vol" ".webtrees-bundled-version")
    if [[ "$preserved" != "2.2.5" ]]; then
        results+=("FAIL  state 6 (no-overwrite): marker changed from 2.2.5 to '$preserved'")
        fail=$((fail + 1))
    fi
    vol_rm "$vol"
}

#
# State 7: marker present + tree corrupt (no index.php) → fail fast
#
test_state_7_marker_no_tree() {
    local vol; vol=$(mk_vol) || { vol_create_failed "${FUNCNAME[0]}"; return; }
    vol_prep "$vol" 'echo 2.2.6 > /v/.webtrees-bundled-version'
    run_entrypoint_test \
        "state 7: marker present + index.php missing → fail fast" \
        "-v $vol:/var/www/html -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6" \
        1 \
        "index.php is missing" \
        ""
    vol_rm "$vol"
}

#
# State 8: empty marker → fail fast
#
test_state_8_empty_marker() {
    local vol; vol=$(mk_vol) || { vol_create_failed "${FUNCNAME[0]}"; return; }
    vol_prep "$vol" 'mkdir -p /v/public && cp -a /opt/webtrees-dist/html/public/. /v/public/ && : > /v/.webtrees-bundled-version'
    run_entrypoint_test \
        "state 8: empty marker → fail fast" \
        "-v $vol:/var/www/html -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6" \
        1 \
        "Seed marker is empty" \
        ""
    vol_rm "$vol"
}

#
# Image content: upgrade-lock patch applied
#
test_image_upgrade_lock_patch() {
    local out
    out=$(docker run --rm --entrypoint=/bin/sh "$IMAGE" \
        -c 'grep -c "Upgrade-lock: bundled image is immutable" /opt/webtrees-dist/html/vendor/fisharebest/webtrees/app/Services/UpgradeService.php' 2>&1)

    if [[ "$out" == "1" ]]; then
        results+=("PASS  image: upgrade-lock patch applied in UpgradeService.php")
        pass=$((pass + 1))
    else
        results+=("FAIL  image upgrade-lock — grep count: $out (expected 1)")
        fail=$((fail + 1))
    fi
}

#
# Image content: VendorModuleService patch applied
#
test_image_vendor_module_service_patch() {
    local out exit_code
    set +e
    out=$(docker run --rm --entrypoint=/bin/sh "$IMAGE" \
        -c 'test -f /opt/webtrees-dist/html/vendor/fisharebest/webtrees/app/Services/Composer/VendorModuleService.php \
            && grep -q "vendorModules" /opt/webtrees-dist/html/vendor/fisharebest/webtrees/app/Services/ModuleService.php' 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]]; then
        results+=("PASS  image: VendorModuleService patch applied")
        pass=$((pass + 1))
    else
        results+=("FAIL  image vendor-module-service — exit=$exit_code, got: $out")
        fail=$((fail + 1))
    fi
}

#
# State 9: chown scope — media bind-mount must not be chowned (host UID preserved)
#
test_state_9_chown_scope() {
    # tmpfs media at uid 999:999, run seed, verify the bind-mounted media
    # path keeps its 999:999 owner while /var/www/html/public ends up www-data:82.
    local out
    out=$(docker run --rm --entrypoint=/bin/bash \
        --tmpfs /var/www/html:exec,uid=82,gid=82 \
        --tmpfs /var/www/html/data/media:exec,uid=999,gid=999 \
        -e WEBTREES_AUTO_SEED=true -e WEBTREES_VERSION=2.2.6 \
        "${PHP_ENV[@]}" "$IMAGE" \
        -c '/docker-entrypoint.sh true && stat -c "media=%u:%g public=$(stat -c %u:%g /var/www/html/public)" /var/www/html/data/media')

    if [[ "$out" != *"media=999:999"* ]]; then
        results+=("FAIL  state 9 (chown scope): media owner changed — got: $out")
        fail=$((fail + 1))
    elif [[ "$out" != *"public=82:82"* ]]; then
        results+=("FAIL  state 9 (chown scope): public owner not www-data — got: $out")
        fail=$((fail + 1))
    else
        results+=("PASS  state 9: chown of /var/www/html scoped, media bind-mount untouched")
        pass=$((pass + 1))
    fi
}

#
# Image content: DATA_DIR symlink redirects webtrees vendor → /var/www/html/data
#
test_image_data_symlink() {
    local out exit_code
    set +e
    out=$(docker run --rm --entrypoint=/bin/sh "$IMAGE" \
        -c 'test -L /opt/webtrees-dist/html/vendor/fisharebest/webtrees/data \
            && target=$(readlink /opt/webtrees-dist/html/vendor/fisharebest/webtrees/data) \
            && [ "$target" = "../../../data" ] \
            && test -f /opt/webtrees-dist/html/data/.htaccess' 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]]; then
        results+=("PASS  image: vendor/.../data → ../../../data symlink, html/data populated")
        pass=$((pass + 1))
    else
        results+=("FAIL  image data-symlink — exit=$exit_code, got: $out")
        fail=$((fail + 1))
    fi
}

#
# _FILE secret pattern: FOO_FILE=/path → expand to FOO=$(cat /path), unset FOO_FILE
#
test_file_secrets_resolve() {
    # Use a temp file passed in via tmpfs/copy.
    local out
    out=$(docker run --rm --entrypoint=/bin/bash \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        "${PHP_ENV[@]}" "$IMAGE" \
        -c 'mkdir -p /run/secrets && echo "supersecret" > /run/secrets/db && export MARIADB_PASSWORD_FILE=/run/secrets/db && /docker-entrypoint.sh sh -c "echo MARIADB_PASSWORD=\$MARIADB_PASSWORD MARIADB_PASSWORD_FILE=\${MARIADB_PASSWORD_FILE:-unset}"' 2>&1)

    if [[ "$out" == *"MARIADB_PASSWORD=supersecret"* ]] && [[ "$out" == *"MARIADB_PASSWORD_FILE=unset"* ]]; then
        results+=("PASS  file-secrets: FOO_FILE expanded to FOO and FOO_FILE unset")
        pass=$((pass + 1))
    else
        results+=("FAIL  file-secrets — got: $out")
        fail=$((fail + 1))
    fi
}

#
# _FILE secret pattern: COMPOSE_FILE meta-var is skipped (regression guard)
#
test_file_secrets_skips_compose_file() {
    local out exit_code
    set +e
    out=$(docker run --rm --entrypoint=/bin/bash \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -e COMPOSE_FILE=compose.yaml:compose.publish.yaml \
        "${PHP_ENV[@]}" "$IMAGE" \
        -c '/docker-entrypoint.sh true' 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]] && ! grep -q "does not exist" <<<"$out"; then
        results+=("PASS  file-secrets: COMPOSE_FILE is not treated as a secret reference")
        pass=$((pass + 1))
    else
        results+=("FAIL  file-secrets COMPOSE_FILE skip — exit=$exit_code, got: $(head -3 <<<"$out" | tr '\n' '|')")
        fail=$((fail + 1))
    fi
}

#
# _FILE secret pattern: non-absolute values are skipped (defense-in-depth)
#
test_file_secrets_skips_relative_paths() {
    local out exit_code
    set +e
    out=$(docker run --rm --entrypoint=/bin/bash \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -e SOMETHING_FILE=relative/value \
        "${PHP_ENV[@]}" "$IMAGE" \
        -c '/docker-entrypoint.sh true' 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]] && ! grep -q "does not exist" <<<"$out"; then
        results+=("PASS  file-secrets: relative-path values are skipped")
        pass=$((pass + 1))
    else
        results+=("FAIL  file-secrets relative skip — exit=$exit_code, got: $(head -3 <<<"$out" | tr '\n' '|')")
        fail=$((fail + 1))
    fi
}

#
# _FILE secret pattern: missing file → fail fast
#
test_file_secrets_missing() {
    local out exit_code
    set +e
    out=$(docker run --rm --entrypoint=/bin/bash \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -e MARIADB_PASSWORD_FILE=/run/secrets/nonexistent \
        "${PHP_ENV[@]}" "$IMAGE" \
        -c '/docker-entrypoint.sh true' 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 1 ]] && grep -q "the file does not exist" <<<"$out"; then
        results+=("PASS  file-secrets: missing file fails fast")
        pass=$((pass + 1))
    else
        results+=("FAIL  file-secrets missing — exit=$exit_code, got: $(head -3 <<<"$out" | tr '\n' '|')")
        fail=$((fail + 1))
    fi
}

# ============================================================================
# Bootstrap-Hook tests (setup_webtrees_bootstrap)
# ============================================================================

# Pre-seed a volume so the seed state machine passes and the bootstrap
# function reaches its decision branches.
bootstrap_prep_volume() {
    local vol="$1"
    # Pre-create the stub-log world-writable so the php stub can append
    # to it from `su www-data` (volume root is 755 owned by root).
    vol_prep "$vol" 'mkdir -p /v/public /v/data && \
        echo "2.2.6" > /v/.webtrees-bundled-version && \
        touch /v/public/index.php && \
        touch /v/data/.htaccess && \
        touch /v/.bootstrap-stub.log && \
        chmod 666 /v/.bootstrap-stub.log'
}

test_bootstrap_noop_without_admin_user() {
    local name="bootstrap: no-op when WT_ADMIN_USER unset"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    local out exit_code
    set +e
    out=$(docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        php-fpm -t 2>&1)
    exit_code=$?
    set -e

    # The php-fpm -t invocation will exit 0 once the entrypoint completes.
    # If the bootstrap-hook had run, the stub would have logged something.
    local stub_calls
    stub_calls=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null | wc -l')

    if [[ "$stub_calls" -eq 0 ]] && ! echo "$out" | grep -qi "bootstrap"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — stub_calls=$stub_calls, output had 'bootstrap': $(echo "$out" | grep -ci bootstrap)")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_fails_without_password() {
    local name="bootstrap: fails when WT_ADMIN_USER set but password missing"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    local out exit_code
    set +e
    out=$(docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        php-fpm -t 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -ne 0 ]] && echo "$out" | grep -q "WT_ADMIN_PASSWORD is empty"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — expected non-zero exit + 'WT_ADMIN_PASSWORD is empty', got exit=$exit_code, output=$(echo "$out" | tail -5)")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_sets_marker_on_success() {
    local name="bootstrap: marker file present after successful run"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local marker_present
    marker_present=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c '[ -f /v/.webtrees-bootstrapped ] && echo yes || echo no')

    if [[ "$marker_present" == "yes" ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — marker missing after bootstrap")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_single_quote_in_password_is_safe() {
    local name="bootstrap: literal apostrophe in password reaches php verbatim"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    # Password with a literal `'` that would have terminated the
    # previous single-quote-substituted command body, causing either
    # bootstrap-exit-1 (benign) or shell injection (worse). The
    # positional-args refactor passes the value as a discrete argv
    # entry, so the apostrophe stays inside the string.
    local pw="ab'cd1234"
    # ENTRYPOINT_SRC overlay: the positional-args refactor lives in
    # the source tree but is not yet baked into the published image;
    # without the bind-mount the test would exercise the old
    # single-quote-substituted body and fail. Drop the overlay once
    # the fix ships in a tagged image.
    docker run --rm \
        -v "$vol:/var/www/html" \
        -v "$ENTRYPOINT_SRC:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD="$pw" \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD="$pw" \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    # The stub php logs argv to .bootstrap-stub.log; the literal
    # `--password=ab'cd1234` (or `--dbpass=...`) proves the value
    # reached the child process intact. Use grep -F to defeat any
    # accidental regex interpretation of the apostrophe.
    local got
    got=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c "cat /v/.bootstrap-stub.log 2>/dev/null || true")

    if printf '%s\n' "$got" | grep -qF -- "--password=$pw" \
        && printf '%s\n' "$got" | grep -qF -- "--dbpass=$pw"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — apostrophe-bearing password not seen verbatim in php argv")
        results+=("      log tail:")
        printf '%s\n' "$got" | tail -10 | sed 's/^/        /' \
            | while IFS= read -r line; do results+=("$line"); done
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_respects_marker_on_second_run() {
    local name="bootstrap: skips when marker already exists"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"
    # Pre-set the marker so the hook should skip everything
    vol_prep "$vol" 'touch /v/.webtrees-bootstrapped'

    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local stub_calls
    stub_calls=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null | wc -l')

    if [[ "$stub_calls" -eq 0 ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — bootstrap stubbed-php was called $stub_calls times despite marker")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_pretty_urls_flag_propagates() {
    local name="bootstrap: WEBTREES_REWRITE_URLS=1 forwards --rewrite-urls"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    # WEBTREES_REWRITE_URLS=1 → entrypoint should call config-ini with --rewrite-urls.
    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        -e WEBTREES_REWRITE_URLS=1 \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local log
    log=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null || true')

    if grep -q 'config-ini' <<<"$log" \
        && grep -qE -- '(^| )--rewrite-urls( |$)' <<<"$log" \
        && ! grep -qE -- '(^| )--no-rewrite-urls( |$)' <<<"$log"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — --rewrite-urls not in config-ini argv, log=$(head -3 <<<"$log")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_pretty_urls_off_passes_no_rewrite_urls() {
    local name="bootstrap: WEBTREES_REWRITE_URLS=0 forwards --no-rewrite-urls"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        -e WEBTREES_REWRITE_URLS=0 \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local log
    log=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null || true')

    if grep -q 'config-ini' <<<"$log" \
        && grep -qE -- '(^| )--no-rewrite-urls( |$)' <<<"$log" \
        && ! grep -qE -- '(^| )--rewrite-urls( |$)' <<<"$log"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — --no-rewrite-urls not in config-ini argv, log=$(head -3 <<<"$log")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_pretty_urls_accepts_lowercase_true_alias() {
    local name="bootstrap: WEBTREES_REWRITE_URLS=true forwards --rewrite-urls"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        -e WEBTREES_REWRITE_URLS=true \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local log
    log=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null || true')

    if grep -qE -- '(^| )--rewrite-urls( |$)' <<<"$log" \
        && ! grep -qE -- '(^| )--no-rewrite-urls( |$)' <<<"$log"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — --rewrite-urls alias 'true' not honoured, log=$(head -3 <<<"$log")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_pretty_urls_unknown_value_falls_through() {
    local name="bootstrap: WEBTREES_REWRITE_URLS=yes (unknown) falls through with no flag"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        -e WEBTREES_REWRITE_URLS=yes \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local log
    log=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null || true')

    if grep -q 'config-ini' <<<"$log" \
        && ! grep -qE -- '(^| )--rewrite-urls( |$)' <<<"$log" \
        && ! grep -qE -- '(^| )--no-rewrite-urls( |$)' <<<"$log"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — unknown value should fall through with no flag, log=$(head -3 <<<"$log")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_bootstrap_pretty_urls_unset_omits_flag() {
    local name="bootstrap: WEBTREES_REWRITE_URLS unset keeps config-ini default"
    local vol stub
    vol=$(mk_vol) || vol_create_failed "$name" || return
    stub=$(build_stub_image)
    bootstrap_prep_volume "$vol"

    docker run --rm \
        -v "$vol:/var/www/html" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_ADMIN_USER=admin \
        -e WT_ADMIN_EMAIL=admin@example.org \
        -e WT_ADMIN_PASSWORD=test1234 \
        -e MARIADB_HOST=db \
        -e MARIADB_USER=webtrees \
        -e MARIADB_DATABASE=webtrees \
        -e MARIADB_PASSWORD=webtrees \
        "${PHP_ENV[@]}" \
        --entrypoint=/docker-entrypoint.sh \
        "$stub" \
        true >/dev/null 2>&1 || true

    local log
    log=$(docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'cat /v/.bootstrap-stub.log 2>/dev/null || true')

    if grep -q 'config-ini' <<<"$log" \
        && ! grep -qE -- '(^| )--rewrite-urls( |$)' <<<"$log" \
        && ! grep -qE -- '(^| )--no-rewrite-urls( |$)' <<<"$log"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — rewrite-urls flag leaked despite WEBTREES_REWRITE_URLS unset, log=$(head -3 <<<"$log")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

# SMTP tests (#43). The happy-path that writes into site_setting needs
# a running database + a seeded /var/www/html — those land in the smoke
# matrix (build.yml), not in this fast suite. Here we cover the cheap
# no-DB-required paths: no-op-when-unset and pre-DB-call input
# validation.

test_smtp_prefs_noop_when_unset() {
    local name="smtp: WT_SMTP_HOST unset → setup_smtp_prefs is a no-op"
    # Bind-mount the source entrypoint so we exercise setup_smtp_prefs
    # (not the previously-baked setup_mail/msmtp path). Once the next
    # tagged image carries setup_smtp_prefs the overlay can drop.
    local out
    out=$(docker run --rm \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1 | grep -i "Configuring webtrees SMTP" || true' 2>&1)

    if [[ -z "$out" ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — entrypoint logged SMTP activity despite WT_SMTP_HOST unset")
        results+=("      output: $(head -3 <<<"$out")")
        fail=$((fail + 1))
    fi
}

test_smtp_prefs_rejects_newline_injection() {
    local name="smtp: newline in WT_SMTP_HOST refuses to write site_setting"

    set +e
    local out
    out=$(docker run --rm \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_SMTP_HOST=$'evil.tld\nSMTP_HOST attacker.example.org' \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1; echo "exit=$?"' 2>&1)
    set -e

    # Container must exit non-zero AND log the control-char refusal.
    if grep -q '^exit=1$' <<<"$out" && grep -q 'control characters' <<<"$out"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — control-char gate did not refuse the value")
        results+=("      output: $(head -10 <<<"$out")")
        fail=$((fail + 1))
    fi
}

test_smtp_prefs_rejects_malformed_port() {
    local name="smtp: non-numeric WT_SMTP_PORT refuses to write site_setting"

    set +e
    local out
    out=$(docker run --rm \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_SMTP_HOST=relay.example.org \
        -e WT_SMTP_PORT=smtp \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1; echo "exit=$?"' 2>&1)
    set -e

    if grep -q '^exit=1$' <<<"$out" && grep -q "not numeric" <<<"$out"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — port validator did not refuse")
        results+=("      output: $(head -10 <<<"$out")")
        fail=$((fail + 1))
    fi
}

test_smtp_prefs_rejects_whitespace_only_host() {
    local name="smtp: whitespace-only WT_SMTP_HOST refuses to write site_setting"

    set +e
    local out
    out=$(docker run --rm \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_SMTP_HOST=$'\t  ' \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1; echo "exit=$?"' 2>&1)
    set -e

    if grep -q '^exit=1$' <<<"$out" && grep -q 'whitespace-only\|control characters' <<<"$out"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — whitespace-only host should refuse")
        results+=("      output: $(head -10 <<<"$out")")
        fail=$((fail + 1))
    fi
}

test_smtp_prefs_rejects_auth_user_without_password() {
    local name="smtp: WT_SMTP_AUTH_USER set + AUTH_PASSWORD empty refuses (half-configured auth)"

    # Plant a fake launcher + config.ini.php in a volume so the
    # auth-user-without-password check (which runs after the launcher
    # + config.ini.php presence checks) actually gets reached.
    local vol
    vol=$(mk_vol) || vol_create_failed "$name" || return
    docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'mkdir -p /v/public /v/data && touch /v/public/index.php /v/data/config.ini.php' >/dev/null

    set +e
    local out
    out=$(docker run --rm \
        -v "$vol:/var/www/html" \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_SMTP_HOST=relay.example.org \
        -e WT_SMTP_AUTH_USER=alice \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1; echo "exit=$?"' 2>&1)
    set -e

    if grep -q '^exit=1$' <<<"$out" && grep -q 'half-configured SMTP auth' <<<"$out"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — AUTH_USER+no-password should refuse loud")
        results+=("      output: $(head -10 <<<"$out")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_smtp_prefs_skips_when_db_not_initialised() {
    local name="smtp: WT_SMTP_HOST set + config.ini.php absent → warn + skip (browser-setup install)"

    # The validation block all passes; launcher exists (we tmpfs /var/www
    # and the launcher won't exist there either, so we have to fake it).
    # Mount a fake /var/www with the launcher present but config.ini.php
    # absent — this is the browser-setup case the new presence check
    # protects against.
    local vol
    vol=$(mk_vol) || vol_create_failed "$name" || return
    docker run --rm --entrypoint=/bin/sh -v "$vol:/v" "$IMAGE" \
        -c 'mkdir -p /v/public && touch /v/public/index.php' >/dev/null

    set +e
    local out
    out=$(docker run --rm \
        -v "$vol:/var/www/html" \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_SMTP_HOST=relay.example.org \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1; echo "exit=$?"' 2>&1)
    set -e

    # Expect exit 0 + the "DB not initialised yet" warning so the
    # container still boots and the operator can finish setup via the
    # browser wizard.
    if grep -q '^exit=0$' <<<"$out" && grep -q 'DB not initialised yet' <<<"$out"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — should warn + skip rather than crash boot")
        results+=("      output: $(head -10 <<<"$out")")
        fail=$((fail + 1))
    fi

    vol_rm "$vol"
}

test_smtp_prefs_rejects_invalid_ssl_mode() {
    local name="smtp: WT_SMTP_SSL invalid value refuses to write site_setting"

    set +e
    local out
    out=$(docker run --rm \
        --tmpfs /var/www:exec,uid=82,gid=82 \
        -v "${ENTRYPOINT_SRC}:/docker-entrypoint.sh:ro" \
        -e WEBTREES_AUTO_SEED=false \
        -e ENVIRONMENT=production \
        -e WT_SMTP_HOST=relay.example.org \
        -e WT_SMTP_SSL=garbage \
        "${PHP_ENV[@]}" \
        --entrypoint=/bin/sh \
        "$IMAGE" \
        -c '/docker-entrypoint.sh true 2>&1; echo "exit=$?"' 2>&1)
    set -e

    if grep -q '^exit=1$' <<<"$out" && grep -q "WT_SMTP_SSL" <<<"$out"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — SSL-mode validator did not refuse 'garbage'")
        results+=("      output: $(head -10 <<<"$out")")
        fail=$((fail + 1))
    fi
}


main() {
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        printf "Image %s not found locally — build it first (make build).\n" "$IMAGE" >&2
        exit 2
    fi

    printf "Running entrypoint state-machine tests against %s\n\n" "$IMAGE"

    test_state_1_auto_seed_unset
    test_state_2_version_empty
    test_state_3_seed_fresh
    test_state_4_marker_matches
    test_state_5_unmarked_tree
    test_state_6_version_mismatch
    test_state_7_marker_no_tree
    test_state_8_empty_marker
    test_state_9_chown_scope
    test_image_data_symlink
    test_image_upgrade_lock_patch
    test_image_vendor_module_service_patch
    test_file_secrets_resolve
    test_file_secrets_skips_compose_file
    test_file_secrets_skips_relative_paths
    test_file_secrets_missing
    test_bootstrap_noop_without_admin_user
    test_bootstrap_fails_without_password
    test_bootstrap_sets_marker_on_success
    test_bootstrap_single_quote_in_password_is_safe
    test_bootstrap_respects_marker_on_second_run
    test_bootstrap_pretty_urls_flag_propagates
    test_bootstrap_pretty_urls_off_passes_no_rewrite_urls
    test_bootstrap_pretty_urls_unset_omits_flag
    test_bootstrap_pretty_urls_accepts_lowercase_true_alias
    test_bootstrap_pretty_urls_unknown_value_falls_through
    test_smtp_prefs_noop_when_unset
    test_smtp_prefs_rejects_newline_injection
    test_smtp_prefs_rejects_malformed_port
    test_smtp_prefs_rejects_whitespace_only_host
    test_smtp_prefs_rejects_auth_user_without_password
    test_smtp_prefs_skips_when_db_not_initialised
    test_smtp_prefs_rejects_invalid_ssl_mode

    for line in "${results[@]}"; do
        printf "%s\n" "$line"
    done

    printf "\n%d passed, %d failed\n" "$pass" "$fail"

    [[ "$fail" -eq 0 ]] || exit 1
}

main "$@"
