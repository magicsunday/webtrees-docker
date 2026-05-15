#!/bin/sh
# Render the operator-extensible half of the X-Forwarded-Proto trust gate.
#
# trust-proxy-map.conf carries the conservative baked CIDRs in
# $trusted_proxy_default and pulls $trusted_proxy_extra in via
# `include /etc/nginx/includes/trust-proxy-extra.conf`. This script
# REWRITES that include file on every container boot:
#
#   * If NGINX_TRUSTED_PROXIES is set and parses → emit a geo block listing
#     the operator's extra CIDRs (each resolves to 1).
#   * If NGINX_TRUSTED_PROXIES is unset/empty → emit a placeholder geo
#     that resolves $trusted_proxy_extra to 0 for every request.
#
# Always rewriting (rather than skip-when-unset) means a previous boot's
# stale operator-supplied CIDRs cannot survive after the env var is
# cleared on the next start.
#
# Format: comma-separated CIDR list, optionally with whitespace.
#   NGINX_TRUSTED_PROXIES="10.42.0.0/16, 192.168.10.0/24, ::ffff:10.0.0.0/120"
#
# Hard caps and refusals (fail-closed: every malformed input crashes the
# container at this script, before nginx parses the rendered file):
#   * Total raw length capped at 4096 bytes so a huge env var cannot
#     stall startup.
#   * At most 256 entries; beyond that the operator is using the wrong
#     tool (use a different reverse proxy or a CIDR aggregator).
#   * Anchored case-pattern match rejects newlines, semicolons, braces,
#     and anything outside [0-9a-fA-F.:/] — nginx config injection is the
#     primary attack vector.
#   * Wildcard CIDRs (0.0.0.0/0, ::/0, anything ending in /0) are refused
#     because they re-open the very bypass the gate exists to close.
#   * IPv4 prefix bounded to 0..32, IPv6 to 0..128. IPv4-mapped IPv6
#     forms (::ffff:a.b.c.d/N) are accepted under the IPv6 branch.
#
# On post-write nginx -t failure (e.g. duplicate CIDR, IPv6 form the
# regex accepts but nginx rejects) the script exits 1 and the upstream
# entrypoint chain aborts. The rendered file is intentionally left on
# disk so logs reflect the actual input; the container CrashLoopBackOffs
# until the operator corrects NGINX_TRUSTED_PROXIES, and the next boot
# rewrites cleanly. Keep the placeholder geo block byte-identical to the
# baked stub in /etc/nginx/includes/trust-proxy-extra.conf so a future
# variable rename doesn't drift between image-build and runtime.

set -eu

OUT=/etc/nginx/includes/trust-proxy-extra.conf
RAW="${NGINX_TRUSTED_PROXIES:-}"

write_placeholder() {
    cat > "$OUT" <<'EOF'
# Auto-rendered by docker-entrypoint.d/35-trust-proxy-extra.sh.
# NGINX_TRUSTED_PROXIES is unset or empty, so $trusted_proxy_extra
# resolves to 0 for every client; only $trusted_proxy_default applies.
geo $trusted_proxy_extra {
    default 0;
}
EOF
}

reject() {
    printf 'NGINX_TRUSTED_PROXIES: %s\n' "$1" >&2
    exit 1
}

if [ -z "$RAW" ]; then
    write_placeholder
    exit 0
fi

# Cap raw length before any further processing so a deliberately huge
# value cannot DoS startup. 4096 bytes ≈ 80+ longest-form IPv6 CIDRs;
# well beyond any reasonable operator config.
if [ "${#RAW}" -gt 4096 ]; then
    reject "value too long (max 4096 bytes, got ${#RAW})"
fi

# Refuse any character outside the CIDR alphabet + comma/space/tab. This
# is the primary defence against nginx-directive injection: a single
# newline in a comma chunk would let a per-line regex anchor accept a
# legitimate CIDR while a downstream line carrying `default 1;` slips
# through into the geo block. Reject the whole input if any disallowed
# byte is present — no per-entry repair attempts.
#
# Literal newline/CR are captured via single-quoted multi-line strings
# because `$(printf '\n')` is command-substitution-trimmed and would
# collapse to empty (matching every input).
NL='
'
CR=$(printf '\r')
TAB=$(printf '\t')
case $RAW in
    *[!0-9a-fA-F.:/,\ ]*|*"$TAB"*|*"$NL"*|*"$CR"*)
        reject "value contains characters outside the CIDR alphabet"
        ;;
esac

# Validate each entry. Two anchored alternations (IPv4 dotted-quad with
# /0..32, IPv6 hex-with-colons-optionally-IPv4-suffix with /0..128)
# replace the original loose regex; awk matches the whole string, not
# lines, so embedded newlines cannot smuggle extra entries (already
# rejected above, defence-in-depth).
CLEAN=""
COUNT=0
OLD_IFS="$IFS"
IFS=','
for entry in $RAW; do
    entry=$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$entry" ] && continue

    case "$entry" in
        0.0.0.0/0|::/0|*/0)
            IFS="$OLD_IFS"
            reject "refusing wildcard CIDR $entry (would trust every client)"
            ;;
    esac

    if ! printf '%s' "$entry" | awk '
        /^([0-9]{1,3}\.){3}[0-9]{1,3}\/([0-9]|[12][0-9]|3[0-2])$/                   { exit 0 }
        /^[0-9A-Fa-f:.]+:[0-9A-Fa-f:.]*\/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$/    { exit 0 }
        { exit 1 }
    '; then
        IFS="$OLD_IFS"
        reject "refusing malformed entry $entry"
    fi

    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt 256 ]; then
        IFS="$OLD_IFS"
        reject "too many entries (max 256)"
    fi

    CLEAN="${CLEAN}    ${entry} 1;
"
done
IFS="$OLD_IFS"

if [ -z "$CLEAN" ]; then
    # Degenerate input (only commas / whitespace after trim). Render the
    # same placeholder as the unset case so log + file state stay honest.
    write_placeholder
    exit 0
fi

cat > "$OUT" <<EOF
# Auto-rendered by docker-entrypoint.d/35-trust-proxy-extra.sh from
# NGINX_TRUSTED_PROXIES. trust-proxy-map.conf's combiner map OR-merges
# this against the baked \$trusted_proxy_default into the canonical
# \$trusted_proxy. Do NOT bind-mount — overwritten on every boot.
geo \$trusted_proxy_extra {
    default 0;
${CLEAN}}
EOF

# Catch any remaining issues (duplicate CIDR, IPv6 form that survived the
# regex but nginx rejects) here, with the entrypoint as the error origin
# instead of the opaque nginx master crash midway through boot. Skippable
# via TRUST_PROXY_EXTRA_SKIP_NGINX_T=1 for unit tests that exercise the
# rendering logic without setting up the full upstream conf tree; the
# operator-visible warning below logs that the safety net is off so an
# accidental production leak shows up in `docker logs`.
if [ "${TRUST_PROXY_EXTRA_SKIP_NGINX_T:-0}" = "1" ]; then
    printf 'NGINX_TRUSTED_PROXIES: TRUST_PROXY_EXTRA_SKIP_NGINX_T=1 set — skipping post-write nginx -t (do NOT use in production)\n' >&2
else
    NGINX_T_LOG=$(mktemp)
    if ! nginx -t -c /etc/nginx/nginx.conf >"$NGINX_T_LOG" 2>&1; then
        cat "$NGINX_T_LOG" >&2
        rm -f "$NGINX_T_LOG"
        reject "rendered config failed nginx -t (see above)"
    fi
    rm -f "$NGINX_T_LOG"
fi

printf 'NGINX_TRUSTED_PROXIES: extended trust set rendered to %s (%d entries)\n' "$OUT" "$COUNT"
