#!/usr/bin/env bash
#
# Unit-style tests for rootfs/docker-entrypoint.d/35-trust-proxy-extra.sh.
# The script's NGINX_TRUSTED_PROXIES handling is on the trust-gate path
# (#89); a regression here either tanks legitimate HTTPS deployments
# with redirect loops or re-opens the X-Forwarded-Proto bypass.
#
# Strategy: run the script inside the nginx image with /etc/nginx
# writable (the production layout is writable, only the test in
# test-nginx-config.sh mounts it read-only). Suppress the final
# `nginx -t` step via TRUST_PROXY_EXTRA_SKIP_NGINX_T=1 because the test
# harness does not control the full conf.d tree and only wants to verify
# the rendered include file.
#
# Usage:
#   ./tests/test-trust-proxy-extra.sh
#   TEST_NGINX_IMAGE=ghcr.io/magicsunday/webtrees-nginx:1.30-r1 ./tests/test-trust-proxy-extra.sh

set -o nounset -o pipefail

NGINX_IMAGE="${TEST_NGINX_IMAGE:-ghcr.io/magicsunday/webtrees-nginx:1.30-r1}"
SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/rootfs/docker-entrypoint.d/35-trust-proxy-extra.sh"

pass=0
fail=0
results=()

# Run the entrypoint script with a given NGINX_TRUSTED_PROXIES value and
# return its rc + the rendered file contents on stdout (rc-line first,
# then a blank line separator, then the file body).
run_script() {
    local env_value="$1"
    docker run --rm \
        -e "NGINX_TRUSTED_PROXIES=${env_value}" \
        -e "TRUST_PROXY_EXTRA_SKIP_NGINX_T=1" \
        -v "$SCRIPT_PATH:/35-trust-proxy-extra.sh:ro" \
        --entrypoint /bin/sh \
        "$NGINX_IMAGE" \
        -c '
            set +e
            sh /35-trust-proxy-extra.sh >/tmp/stdout 2>/tmp/stderr
            rc=$?
            printf "%s\n" "$rc"
            printf "===STDERR===\n"
            cat /tmp/stderr
            printf "===FILE===\n"
            cat /etc/nginx/includes/trust-proxy-extra.conf 2>/dev/null || true
        '
}

assert_rc() {
    local name="$1" expected_rc="$2" got_rc="$3"
    if [[ "$got_rc" == "$expected_rc" ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
        return 0
    fi
    results+=("FAIL  $name — rc $got_rc (expected $expected_rc)")
    fail=$((fail + 1))
    return 1
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
        return 0
    fi
    results+=("FAIL  $name — '$needle' not in output")
    fail=$((fail + 1))
    return 1
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — unexpected '$needle' in output")
        fail=$((fail + 1))
    fi
}

split_run() {
    # $1: full run_script output. Sets rc, stderr, file globals.
    local raw="$1"
    rc=$(printf '%s\n' "$raw" | head -n1)
    stderr=$(printf '%s\n' "$raw" | awk '/===STDERR===/{flag=1;next}/===FILE===/{flag=0}flag')
    file=$(printf '%s\n' "$raw" | awk '/===FILE===/{flag=1;next}flag')
}

test_unset_renders_placeholder() {
    split_run "$(run_script "")"
    assert_rc "unset → rc 0" 0 "$rc"
    assert_contains "unset → placeholder geo block" "geo \$trusted_proxy_extra" "$file"
    assert_contains "unset → default 0" "default 0;" "$file"
    assert_not_contains "unset → no operator CIDR leaks in" "1;" "$(grep -v default <<<"$file" || true)"
}

test_single_cidr() {
    split_run "$(run_script "10.42.0.0/16")"
    assert_rc "single CIDR → rc 0" 0 "$rc"
    assert_contains "single CIDR → geo block" "geo \$trusted_proxy_extra" "$file"
    assert_contains "single CIDR → entry rendered as '<cidr> 1;'" "10.42.0.0/16 1;" "$file"
}

test_multi_cidr_with_whitespace() {
    split_run "$(run_script "10.42.0.0/16, 192.168.10.0/24 , fd00::/64")"
    assert_rc "multi CIDR → rc 0" 0 "$rc"
    assert_contains "multi CIDR → v4 first" "10.42.0.0/16 1;" "$file"
    assert_contains "multi CIDR → v4 second" "192.168.10.0/24 1;" "$file"
    assert_contains "multi CIDR → v6" "fd00::/64 1;" "$file"
}

test_wildcard_refused() {
    split_run "$(run_script "0.0.0.0/0")"
    assert_rc "wildcard /0 → rc 1" 1 "$rc"
    assert_contains "wildcard /0 → log says 'wildcard CIDR'" "wildcard CIDR" "$stderr"
}

test_v6_wildcard_refused() {
    split_run "$(run_script "::/0")"
    assert_rc "::/0 → rc 1" 1 "$rc"
    assert_contains "::/0 → log says 'wildcard CIDR'" "wildcard CIDR" "$stderr"
}

test_arbitrary_slash_zero_refused() {
    split_run "$(run_script "10.0.0.0/0")"
    assert_rc "10.0.0.0/0 → rc 1" 1 "$rc"
    assert_contains "/0 → log says 'wildcard CIDR'" "wildcard CIDR" "$stderr"
}

test_invalid_prefix_refused() {
    split_run "$(run_script "10.0.0.0/33")"
    assert_rc "v4 /33 → rc 1" 1 "$rc"
    assert_contains "v4 /33 → log says 'malformed'" "malformed entry" "$stderr"
}

test_invalid_ipv6_prefix_refused() {
    split_run "$(run_script "::/130")"
    assert_rc "v6 /130 → rc 1" 1 "$rc"
    assert_contains "v6 /130 → log says 'malformed'" "malformed entry" "$stderr"
}

test_garbage_refused() {
    split_run "$(run_script "not-a-cidr")"
    assert_rc "garbage → rc 1" 1 "$rc"
}

test_disallowed_alphabet_refused() {
    # Smuggle a semicolon — config-injection attempt.
    split_run "$(run_script "10.0.0.0/8; rm -rf /")"
    assert_rc "semicolon → rc 1" 1 "$rc"
    assert_contains "semicolon → log says 'characters outside'" "outside the CIDR alphabet" "$stderr"
}

test_newline_injection_refused() {
    # The critical security regression: a multi-line entry where one line
    # is a valid CIDR and another carries a nginx directive must NOT slip
    # through. The script rejects newlines via the alphabet gate.
    local payload
    payload=$'10.0.0.0/16\n    default 1;\n    127.0.0.1/32'
    split_run "$(run_script "$payload")"
    assert_rc "newline injection → rc 1" 1 "$rc"
    assert_contains "newline injection → log says 'characters outside'" "outside the CIDR alphabet" "$stderr"
}

test_over_4kb_refused() {
    local big_value
    big_value=$(yes 10.0.0.0/8 | head -n 500 | paste -sd',' -)
    split_run "$(run_script "$big_value")"
    assert_rc "huge value → rc 1" 1 "$rc"
    assert_contains "huge value → log says 'too long' or 'too many'" "too long" "$stderr" \
        || assert_contains "huge value → log says 'too many'" "too many entries" "$stderr"
}

test_idempotent_rewrite_clears_stale() {
    # First boot with var set, second boot with var unset → file must
    # not retain the operator CIDR.
    split_run "$(run_script "10.42.0.0/16")"
    assert_contains "stale-check setup → first boot rendered operator CIDR" "10.42.0.0/16 1;" "$file"

    split_run "$(run_script "")"
    assert_rc "stale-check → second boot rc 0" 0 "$rc"
    assert_not_contains "stale-check → operator CIDR removed after env clears" "10.42.0.0/16" "$file"
}

test_cr_injection_refused() {
    # Defence-in-depth: same exploit class as the newline injection
    # case, but using carriage-return only.
    local payload
    payload=$'10.0.0.0/16\r    default 1;'
    split_run "$(run_script "$payload")"
    assert_rc "CR injection → rc 1" 1 "$rc"
    assert_contains "CR injection → log says 'characters outside'" "outside the CIDR alphabet" "$stderr"
}

test_ipv4_mapped_ipv6_accepted() {
    # ::ffff:a.b.c.d/N is the RFC 4291 §2.5.5 IPv4-mapped IPv6 form. A
    # dual-stack reverse proxy that NATs IPv4 traffic into a v6 socket
    # presents source addresses in this notation; the gate must accept it.
    split_run "$(run_script "::ffff:10.0.0.0/120")"
    assert_rc "IPv4-mapped IPv6 → rc 0" 0 "$rc"
    assert_contains "IPv4-mapped IPv6 → rendered entry" "::ffff:10.0.0.0/120 1;" "$file"
}

test_degenerate_csv_renders_placeholder() {
    # Only commas + whitespace after trim → all entries `continue`d, no
    # awk validation hit. The empty-CLEAN fallback writes the placeholder
    # so the file is still well-formed.
    split_run "$(run_script ", , ,  ")"
    assert_rc "degenerate CSV → rc 0" 0 "$rc"
    assert_contains "degenerate CSV → placeholder geo" "geo \$trusted_proxy_extra" "$file"
    assert_not_contains "degenerate CSV → no operator entries" "1;" "$(grep -v default <<<"$file" || true)"
}

test_trailing_comma_accepted() {
    split_run "$(run_script "10.42.0.0/16,")"
    assert_rc "trailing comma → rc 0" 0 "$rc"
    assert_contains "trailing comma → entry kept" "10.42.0.0/16 1;" "$file"
}

test_leading_zero_prefix_refused() {
    # Wildcard guard uses `*/0` and won't catch `/00`; the awk regex
    # then rejects because [0-9] matches a single digit. Defence-in-depth
    # check that the second layer holds.
    split_run "$(run_script "10.0.0.0/00")"
    assert_rc "leading-zero prefix → rc 1" 1 "$rc"
    assert_contains "leading-zero prefix → log says 'malformed'" "malformed entry" "$stderr"
}

test_high_bit_byte_refused() {
    # Defence in depth on the alphabet gate's negated bracket. Use a
    # latin-1 byte that is not in [0-9a-fA-F.:/,\ ].
    split_run "$(run_script "10.0.0.0/8ä")"
    assert_rc "high-bit byte → rc 1" 1 "$rc"
    assert_contains "high-bit byte → log says 'characters outside'" "outside the CIDR alphabet" "$stderr"
}

test_entry_count_boundary() {
    # 256 entries should pass; the 257th must trip the count cap.
    local exact
    exact=$(yes 10.0.0.0/8 | head -n 256 | paste -sd',' -)
    split_run "$(run_script "$exact")"
    assert_rc "256 entries (boundary) → rc 0" 0 "$rc"

    local over
    over=$(yes 10.0.0.0/8 | head -n 257 | paste -sd',' -)
    split_run "$(run_script "$over")"
    assert_rc "257 entries → rc 1" 1 "$rc"
    assert_contains "257 entries → log says 'too many'" "too many entries" "$stderr"
}

test_skip_flag_warns() {
    # The escape hatch must log a clear warning so an accidental
    # production leak surfaces in `docker logs`.
    split_run "$(run_script "10.42.0.0/16")"
    assert_contains "SKIP=1 → warning logged" "do NOT use in production" "$stderr"
}

main() {
    if ! docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
        printf "Image %s not found locally — build it first (make build).\n" "$NGINX_IMAGE" >&2
        exit 2
    fi

    printf "Running trust-proxy-extra tests against %s\n\n" "$NGINX_IMAGE"

    test_unset_renders_placeholder
    test_single_cidr
    test_multi_cidr_with_whitespace
    test_wildcard_refused
    test_v6_wildcard_refused
    test_arbitrary_slash_zero_refused
    test_invalid_prefix_refused
    test_invalid_ipv6_prefix_refused
    test_garbage_refused
    test_disallowed_alphabet_refused
    test_newline_injection_refused
    test_over_4kb_refused
    test_idempotent_rewrite_clears_stale
    test_cr_injection_refused
    test_ipv4_mapped_ipv6_accepted
    test_degenerate_csv_renders_placeholder
    test_trailing_comma_accepted
    test_leading_zero_prefix_refused
    test_high_bit_byte_refused
    test_entry_count_boundary
    test_skip_flag_warns

    for line in "${results[@]}"; do
        printf "%s\n" "$line"
    done

    printf "\n%d passed, %d failed\n" "$pass" "$fail"
    [[ "$fail" -eq 0 ]] || exit 1
}

main "$@"
