#!/usr/bin/env bash
#
# nginx config tests covering the rootfs/etc/nginx/ source-tree state:
#
#   (a) nginx -t syntax check on the merged conf.d + includes after the
#       envsubst-template pre-render the production startup performs.
#   (b) Regression guard for the X-Forwarded-Proto trust gate (#76):
#       trust-proxy-map.conf carries the expected CIDR set, and
#       default.conf reads $xfp_https rather than the raw header — so a
#       future "cleanup" cannot silently re-open the LAN bypass.
#
# Usage:
#   ./tests/test-nginx-config.sh
#   TEST_NGINX_IMAGE=ghcr.io/magicsunday/webtrees/nginx:1.28-r1 ./tests/test-nginx-config.sh

set -o errexit -o nounset -o pipefail

NGINX_IMAGE="${TEST_NGINX_IMAGE:-ghcr.io/magicsunday/webtrees/nginx:1.28-r1}"
ROOTFS_NGINX="$(cd "$(dirname "$0")/.." && pwd)/rootfs/etc/nginx"

pass=0
fail=0
results=()

cleanup_dir=""
cleanup() {
    [[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"
}
trap cleanup EXIT

# Render the envsubst variable template into a static include so nginx -t
# can resolve $enforce_https without booting the image's entrypoint.
prepare_test_tree() {
    cleanup_dir=$(mktemp -d)
    cp -r "$ROOTFS_NGINX/conf.d" "$cleanup_dir/"
    cp -r "$ROOTFS_NGINX/includes" "$cleanup_dir/"
    cat > "$cleanup_dir/conf.d/00-variables.conf" <<EOF
map \$host \$enforce_https {
    default "TRUE";
}
EOF
}

test_nginx_config_syntax() {
    local name="nginx -t: rootfs config parses cleanly"
    local output
    set +e
    output=$(docker run --rm \
        --add-host=phpfpm:127.0.0.1 \
        -v "$cleanup_dir/conf.d:/etc/nginx/conf.d:ro" \
        -v "$cleanup_dir/includes:/etc/nginx/includes:ro" \
        --entrypoint nginx \
        "$NGINX_IMAGE" -t 2>&1)
    local rc=$?
    set -e

    # Avoid `echo … | grep -q` under pipefail (AGENTS.md "Recent traps"):
    # grep -q closes stdin early, echo gets SIGPIPE, pipefail fails the
    # whole pipeline. Use a here-string instead.
    if [[ "$rc" == 0 ]] && grep -q "syntax is ok" <<<"$output"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — exit $rc")
        results+=("      output: $output")
        fail=$((fail + 1))
    fi
}

test_trust_proxy_map_invariants() {
    local name="trust-proxy-map.conf: trusted CIDRs map to 1, LAN ranges absent, map keys intact"
    local conf="$ROOTFS_NGINX/includes/trust-proxy-map.conf"

    # Strip full-line comments so the cautionary "do NOT trust" comment
    # block does not register as live config.
    local active
    active=$(grep -vE '^[[:space:]]*#' "$conf")

    # geo block must declare `default 0;` — flipping to 1 would invert
    # the trust default and trust every previously-untrusted source.
    if ! grep -qE '^[[:space:]]+default[[:space:]]+0;' <<<"$active"; then
        results+=("FAIL  $name — geo block missing 'default 0;' fallback")
        fail=$((fail + 1))
        return
    fi

    # Trusted CIDRs: each must appear as `<cidr> 1;` on its own line.
    # The pattern subsumes the membership check (present AND maps to 1).
    local trusted=("127.0.0.0/8" "::1/128" "172.16.0.0/12" "fc00::/7")
    local missing=()
    for cidr in "${trusted[@]}"; do
        local escaped="${cidr//./\\.}"
        grep -qE "^[[:space:]]+${escaped}[[:space:]]+1;" <<<"$active" \
            || missing+=("$cidr")
    done

    # Forbidden CIDRs: common LAN ranges must NOT be in default trust —
    # adding them re-opens the LAN-attacker spoof path the include
    # exists to close.
    local lan=("10.0.0.0/8" "192.168.0.0/16")
    local forbidden=()
    for cidr in "${lan[@]}"; do
        grep -qF "$cidr" <<<"$active" && forbidden+=("$cidr") || true
    done

    # Map header signatures — single source of truth for both the
    # existence-greps and the awk block extractors below. A future
    # rename only needs to change these two lines.
    # shellcheck disable=SC2016  # nginx variables are literal strings in the config
    local xfp_https_map_header='map "$trusted_proxy:$xfp_scheme" $xfp_https'
    # shellcheck disable=SC2016  # nginx variables are literal strings in the config
    local xfp_scheme_map_header='map $http_x_forwarded_proto $xfp_scheme'

    # $xfp_https composite map must key on (trust × normalised scheme).
    # A bare-header key here would silently re-open the bypass.
    local map_key_ok=1
    grep -qF "$xfp_https_map_header" "$conf" || map_key_ok=0

    # The scheme-normalise map must exist so case variants and comma-lists
    # (RFC 7239 §5.4) collapse to a fixed token before the trust composite.
    local scheme_map_ok=1
    grep -qF "$xfp_scheme_map_header" "$conf" || scheme_map_ok=0

    # Both maps' `default` branch MUST resolve to empty-string. A typo
    # flipping $xfp_https default to `on` (or to `"on"`, or to any
    # truthy value, quoted or bare) would treat every untrusted source
    # as legitimate and reopen the bypass. The same hardening applies
    # to $xfp_scheme as defence in depth. Scope each assertion to the
    # specific map block (awk extracts the body) so a stray `default ""`
    # in some unrelated future map cannot "cover for" a flipped default
    # in the gate-critical maps.
    extract_map_block() {
        local header="$1"
        # Use index() so the header is a literal-string match — no regex
        # escaping needed for `$`, `"`, or `{`. The block opens on the
        # line containing both `$header` and `{`, and closes on the next
        # line that starts with `}`.
        awk -v hdr="$header" '
            index($0, hdr) && /\{/ { in_block=1 }
            in_block
            in_block && /^\}/ { exit }
        ' "$conf"
    }

    check_map_default_closed() {
        local block="$1"
        # Empty block → header pattern did not match. Caller surfaces.
        [[ -n "$block" ]] || return 1
        # Structural invariant rather than truthy-keyword allowlist:
        # the block must carry EXACTLY ONE `default` branch, and that
        # branch must resolve to empty-string. Any other shape — two
        # `default` lines (nginx applies the last one), a truthy literal,
        # a $var-driven value — fails the gate. This is exhaustive and
        # future-proof: it does not depend on tracking nginx's evolving
        # truthy-token vocabulary.
        local default_lines
        mapfile -t default_lines < <(
            grep -E '^[[:space:]]+default[[:space:]]' <<<"$block"
        )
        [[ ${#default_lines[@]} -eq 1 ]] || return 1
        # Allow optional whitespace + optional trailing comment after
        # the `;` — `default "";` and `default "" ; # note` are both
        # legal nginx; rejecting either would be a stylistic
        # false-positive, not a security one.
        [[ "${default_lines[0]}" =~ ^[[:space:]]+default[[:space:]]+\"\"[[:space:]]*\;[[:space:]]*(#.*)?$ ]] \
            || return 1
        return 0
    }

    local xfp_block scheme_block
    xfp_block=$(extract_map_block "$xfp_https_map_header")
    scheme_block=$(extract_map_block "$xfp_scheme_map_header")

    local xfp_default_closed=1 scheme_default_closed=1
    check_map_default_closed "$xfp_block"    || xfp_default_closed=0
    check_map_default_closed "$scheme_block" || scheme_default_closed=0

    if [[ ${#missing[@]} -eq 0 ]] \
        && [[ ${#forbidden[@]} -eq 0 ]] \
        && [[ "$map_key_ok" == 1 ]] \
        && [[ "$scheme_map_ok" == 1 ]] \
        && [[ "$xfp_default_closed" == 1 ]] \
        && [[ "$scheme_default_closed" == 1 ]]; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name")
        [[ ${#missing[@]}          -gt 0 ]] && results+=("      CIDRs not mapped to 1: ${missing[*]}")
        [[ ${#forbidden[@]}        -gt 0 ]] && results+=("      LAN CIDRs in default trust: ${forbidden[*]}")
        [[ "$map_key_ok"           == 0 ]] && results+=("      \$xfp_https map key not '\$trusted_proxy:\$xfp_scheme'")
        [[ "$scheme_map_ok"        == 0 ]] && results+=("      \$xfp_scheme normalisation map missing")
        [[ "$xfp_default_closed"   == 0 ]] && results+=("      \$xfp_https default branch is not 'default \"\";' (typo would reopen bypass)")
        [[ "$scheme_default_closed" == 0 ]] && results+=("      \$xfp_scheme default branch is not 'default \"\";'")
        fail=$((fail + 1))
    fi
}

test_default_conf_reads_xfp_https_not_raw_header() {
    local name="default.conf reads \$xfp_https; no raw \$http_x_forwarded_proto consumer"
    local conf="$ROOTFS_NGINX/conf.d/default.conf"

    # Inside the $isHttps `if` block we want $xfp_https, NOT the raw header.
    # shellcheck disable=SC2016  # nginx variable is a literal grep target
    if ! grep -qE 'if \(\$xfp_https = on\)' "$conf"; then
        results+=("FAIL  $name — \$xfp_https reference not found")
        fail=$((fail + 1))
        return
    fi

    # Catch-all assertion: $http_x_forwarded_proto must not appear in
    # default.conf at all. The only legitimate consumer is the geo+map
    # in trust-proxy-map.conf. This catches not just the
    # `if ($http_x_forwarded_proto = https)` form but also quoted
    # variants, regex-tilde shapes, and `set $isHttps $http_x_forwarded_proto;`
    # — every shape that reintroduces a non-gated reader of the header.
    # shellcheck disable=SC2016  # nginx variable is a literal grep target
    if grep -vE '^[[:space:]]*#' "$conf" | grep -qF '$http_x_forwarded_proto'; then
        results+=("FAIL  $name — raw \$http_x_forwarded_proto consumer still in default.conf")
        fail=$((fail + 1))
        return
    fi

    results+=("PASS  $name")
    pass=$((pass + 1))
}

test_default_conf_includes_trust_proxy_map() {
    local name="default.conf includes trust-proxy-map.conf"
    local conf="$ROOTFS_NGINX/conf.d/default.conf"

    if grep -qE 'include includes/trust-proxy-map\.conf;' "$conf"; then
        results+=("PASS  $name")
        pass=$((pass + 1))
    else
        results+=("FAIL  $name — include directive missing")
        fail=$((fail + 1))
    fi
}

main() {
    if ! docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
        printf "Image %s not found locally — build it first (make build).\n" "$NGINX_IMAGE" >&2
        exit 2
    fi

    printf "Running nginx config tests against %s\n\n" "$NGINX_IMAGE"

    prepare_test_tree

    test_nginx_config_syntax
    test_default_conf_includes_trust_proxy_map
    test_default_conf_reads_xfp_https_not_raw_header
    test_trust_proxy_map_invariants

    for line in "${results[@]}"; do
        printf "%s\n" "$line"
    done

    printf "\n%d passed, %d failed\n" "$pass" "$fail"

    [[ "$fail" -eq 0 ]] || exit 1
}

main "$@"
