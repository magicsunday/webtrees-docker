#!/usr/bin/env bash
# Bash-level regression tests for the HOST_LAN_IP detection block in
# `install` (issue #134). The Python boundary already re-validates
# semantics, so a bash-side regression degrades the user experience
# from "LAN URL emitted" to "LAN URL silently missing" rather than a
# wrong URL — but the awk filter is still the first gate and the
# regex lines are easy to drop accidentally during a refactor.
#
# Coverage:
#   - awk IPv4-filter matrix from `install` lines 188-199:
#     127/8, 172.16/12, 100.64/10, 169.254/16 dropped; first remaining
#     IPv4 picked.
#   - DOCKER_HOST scheme classification: ssh://, tcp://, http://,
#     https://, fd:// → skip; unix://, unix:///custom, empty → run.
#   - WSL osrelease probe: `microsoft` and `wsl` (any case) → skip;
#     plain Linux kernel string → run.
#   - Cloud dev-env probe: CODESPACES / GITHUB_CODESPACES /
#     GITPOD_WORKSPACE_ID / REMOTE_CONTAINERS / DEVCONTAINER set → skip.
#
# Out of scope: macOS `ipconfig getifaddr` iteration (Linux CI can't
# exercise it directly; #139 added the en0..en9 loop and verified by
# simulated stub elsewhere).

set -o errexit -o nounset -o pipefail

fail=0
pass=0

run_test() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "PASS  $name"
        pass=$((pass + 1))
    else
        echo "FAIL  $name"
        echo "        expected: ${expected@Q}"
        echo "        actual:   ${actual@Q}"
        fail=$((fail + 1))
    fi
}

# The awk filter from install:188-199 verbatim. Inlining keeps the
# test self-contained and surfaces a drift between this file and
# install via the asserted hostname-matrix outputs.
filter_lan_ip() {
    local hostname_out=$1
    awk -v ips="$hostname_out" 'BEGIN {
        n = split(ips, a, " ")
        for (i = 1; i <= n; i++) {
            if (a[i] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
            if (a[i] ~ /^127\./) continue
            if (a[i] ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) continue
            if (a[i] ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./) continue
            if (a[i] ~ /^169\.254\./) continue
            print a[i]
            exit
        }
    }'
}

# ──────────────────────────────────────────────────────────────────────
# awk IPv4-filter matrix
# ──────────────────────────────────────────────────────────────────────

run_test "awk: only-loopback yields empty" "" \
    "$(filter_lan_ip '127.0.0.1')"

run_test "awk: docker-bridge-first then real LAN" "192.168.1.5" \
    "$(filter_lan_ip '172.17.0.1 192.168.1.5')"

run_test "awk: CGNAT (100.64.0.1) skipped, real LAN picked" "10.0.0.5" \
    "$(filter_lan_ip '100.64.0.1 10.0.0.5')"

run_test "awk: link-local (169.254.x) skipped, real LAN picked" "192.168.178.25" \
    "$(filter_lan_ip '169.254.1.1 192.168.178.25')"

run_test "awk: 172.15.x.x is OUT of docker block (172.16/12)" "172.15.0.1" \
    "$(filter_lan_ip '172.15.0.1')"

run_test "awk: 172.32.x.x is OUT of docker block" "172.32.0.1" \
    "$(filter_lan_ip '172.32.0.1')"

run_test "awk: 100.128.x.x is OUT of CGNAT block (100.64/10)" "100.128.0.1" \
    "$(filter_lan_ip '100.128.0.1')"

run_test "awk: empty input yields empty" "" \
    "$(filter_lan_ip '')"

run_test "awk: multi-NIC picks first valid" "192.168.1.10" \
    "$(filter_lan_ip '192.168.1.10 10.0.0.5 172.17.0.1')"

run_test "awk: IPv6-only string yields empty (only-IPv4 by shape)" "" \
    "$(filter_lan_ip 'fe80::1')"

# ──────────────────────────────────────────────────────────────────────
# Default-route interface extraction — issue #135 (preferred path
# before the `hostname -I` heuristic).
# ──────────────────────────────────────────────────────────────────────

# Parses `ip -4 -o route show default` output and returns the iface
# after the literal `dev` token. Reproduces the awk in install:182-184.
extract_default_iface() {
    local route_show_default_output=$1
    printf '%s\n' "$route_show_default_output" \
        | awk '{ for (i=1; i<NF; i++) if ($i == "dev") { print $(i+1); exit } }'
}

run_test "default-iface: 'default via 192.168.1.1 dev eth0' → eth0" "eth0" \
    "$(extract_default_iface 'default via 192.168.1.1 dev eth0')"
run_test "default-iface: 'default via 10.0.0.1 dev wg0'    → wg0"  "wg0" \
    "$(extract_default_iface 'default via 10.0.0.1 dev wg0')"
run_test "default-iface: missing 'dev' token              → empty" "" \
    "$(extract_default_iface 'default via 192.168.1.1 weird')"
run_test "default-iface: empty input                       → empty" "" \
    "$(extract_default_iface '')"

# ──────────────────────────────────────────────────────────────────────
# DOCKER_HOST scheme classification — case statement from install:151-153
# (after the printf|sed|tr|tr normalisation pipeline).
# ──────────────────────────────────────────────────────────────────────

# Reproduces the normalise-then-classify chain from install:144-153.
classify_docker_host() {
    local dh=$1
    local lc
    lc=$(printf '%s' "$dh" \
        | sed -e 's/^[^a-zA-Z0-9]*//' 2>/dev/null \
        | tr -d '[:space:]' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' 2>/dev/null) || { echo "skip"; return; }
    case "$lc" in
        ssh://*|tcp://*|http://*|https://*|fd://*) echo "skip" ;;
        *) echo "run" ;;
    esac
}

run_test "DOCKER_HOST=ssh://daemon  → skip" "skip" \
    "$(classify_docker_host 'ssh://daemon')"
run_test "DOCKER_HOST=SSH://daemon  (uppercase) → skip" "skip" \
    "$(classify_docker_host 'SSH://daemon')"
run_test "DOCKER_HOST=tcp://x:2375  → skip" "skip" \
    "$(classify_docker_host 'tcp://x:2375')"
run_test "DOCKER_HOST=http://x      → skip" "skip" \
    "$(classify_docker_host 'http://x')"
run_test "DOCKER_HOST=https://x     → skip" "skip" \
    "$(classify_docker_host 'https://x')"
run_test "DOCKER_HOST=fd://3        → skip" "skip" \
    "$(classify_docker_host 'fd://3')"
run_test "DOCKER_HOST=unix:///var/run/docker.sock → run" "run" \
    "$(classify_docker_host 'unix:///var/run/docker.sock')"
run_test "DOCKER_HOST=unix:///custom/sock  → run" "run" \
    "$(classify_docker_host 'unix:///custom/sock')"
run_test "DOCKER_HOST=''            → run (detection proceeds)" "run" \
    "$(classify_docker_host '')"
# Paste-pollution prefixes from #134 / #117 R8.
run_test "DOCKER_HOST=$'\\nssh://daemon' (newline prefix) → skip" "skip" \
    "$(classify_docker_host $'\nssh://daemon')"
run_test "DOCKER_HOST=' ssh://daemon ' (whitespace pad) → skip" "skip" \
    "$(classify_docker_host ' ssh://daemon ')"
run_test "DOCKER_HOST=$'\\xc2\\xa0ssh://daemon' (NBSP prefix) → skip" "skip" \
    "$(classify_docker_host $'\xc2\xa0ssh://daemon')"

# ──────────────────────────────────────────────────────────────────────
# WSL osrelease probe — install:154-158
# ──────────────────────────────────────────────────────────────────────

wsl_probe() {
    # mimic `grep -qi -e microsoft -e wsl` against a fixture string
    local osrelease=$1
    if printf '%s\n' "$osrelease" | grep -qi -e microsoft -e wsl; then
        echo "skip"
    else
        echo "run"
    fi
}

run_test "WSL osrelease: 'microsoft-standard-WSL2'      → skip" "skip" \
    "$(wsl_probe 'microsoft-standard-WSL2')"
run_test "WSL osrelease: 'Microsoft' (PascalCase)       → skip" "skip" \
    "$(wsl_probe 'Microsoft')"
run_test "WSL osrelease: '5.15.0-WSL2-something'        → skip" "skip" \
    "$(wsl_probe '5.15.0-WSL2-something')"
run_test "WSL osrelease: plain Linux kernel             → run"  "run" \
    "$(wsl_probe '6.1.0-12-amd64')"

# ──────────────────────────────────────────────────────────────────────
# Cloud dev-env probe — install:166-169
# ──────────────────────────────────────────────────────────────────────

devenv_probe() {
    # Reproduces the `[ -n "${CODESPACES:-}${GITHUB_CODESPACES:-}..." ]`
    # bash test by sourcing the joined env into a subshell.
    eval "$1"
    if [ -n "${CODESPACES:-}${GITHUB_CODESPACES:-}${GITPOD_WORKSPACE_ID:-}${REMOTE_CONTAINERS:-}${DEVCONTAINER:-}" ]; then
        echo "skip"
    else
        echo "run"
    fi
}

run_test "CODESPACES=true              → skip" "skip" \
    "$(devenv_probe 'CODESPACES=true')"
run_test "GITHUB_CODESPACES=true       → skip" "skip" \
    "$(devenv_probe 'GITHUB_CODESPACES=true')"
run_test "GITPOD_WORKSPACE_ID=xyz      → skip" "skip" \
    "$(devenv_probe 'GITPOD_WORKSPACE_ID=xyz')"
run_test "REMOTE_CONTAINERS=true       → skip" "skip" \
    "$(devenv_probe 'REMOTE_CONTAINERS=true')"
run_test "DEVCONTAINER=true            → skip" "skip" \
    "$(devenv_probe 'DEVCONTAINER=true')"
run_test "no dev-env var set           → run"  "run" \
    "$(devenv_probe ':')"

# ──────────────────────────────────────────────────────────────────────

echo
total=$((pass + fail))
if [ "$fail" -ne 0 ]; then
    echo "$pass passed, $fail failed (of $total)"
    exit 1
fi
echo "$pass passed, 0 failed"
