#!/usr/bin/env bash
# Asserts no TLS-verify bypass appears in executable repo files.
# Invoked by `make ci-tls-verify-lockstep` (issue #128).
#
# "TLS-Verify" = the cert-validation step every HTTPS client does to
# confirm the server matches the URL. Disabling it turns the connection
# plaintext-equivalent against any MITM with cert-bypass capability —
# a permanent regression the moment one slips in.
#
# Deny-list discipline:
#   * The set is intentionally absolute for executable files. A
#     temporary diagnostic must be removed before commit, NOT
#     committed with an exception marker — exception tables grow
#     silently and the next reviewer cannot tell which entries are
#     still justified.
#   * Operator-facing docs (`docs/`, `README.md`, `CHANGELOG.md`)
#     are out of scope: they describe troubleshooting techniques an
#     operator may need to run against their own infrastructure
#     (e.g. `curl --insecure` to confirm a listener answers). Such
#     mentions are reference text, not invocations.
#
# Failure-path test in `tests/test-lockstep.sh` injects representative
# violations and asserts this script exits non-zero with the expected
# annotation.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

# Boundary group accepted after a `--flag` token: whitespace, EOL, `=`,
# one of the quote/comma/bracket chars a YAML / JSON / shell-array
# literal would put adjacent (e.g. `args: ["--insecure"]`,
# `args: ['--insecure',]`), or a shell statement-separator (`;`, `|`,
# `&`, `>`, `<`) so a one-liner like `curl -k;next` cannot slip past.
# The character class avoids putting `]` inside a bracket-expression
# by listing the literal chars as alternation members instead.
_BOUNDARY='([[:space:]=,;|&<>]|"|'"'"'|\)|\]|$)'

# Each entry below disables certificate validation in a specific HTTPS
# client. The trailing `${_BOUNDARY}` anchor prevents substring
# matches like `--insecure-flag-help` while still catching the flag in
# YAML/JSON sequence literals. Patterns that match a complete token
# (env vars, identifiers, config-file keys) don't need the boundary.
deny_patterns=(
    "--insecure${_BOUNDARY}"                              # curl --insecure
    "\\bcurl[[:space:]]+-[a-zA-Z]*k[a-zA-Z]*${_BOUNDARY}" # curl -k / -kfsSL / -fkSL
    "--no-check-certificate${_BOUNDARY}"                  # wget
    "--no-ssl-verify${_BOUNDARY}"                         # alt. spelling
    "--ssl-no-verify${_BOUNDARY}"                         # alt. spelling
    "--no-verify-ssl${_BOUNDARY}"                         # alt. spelling
    'verify[[:space:]]*=[[:space:]]*False'                # Python requests / urllib3
    'check_hostname[[:space:]]*=[[:space:]]*False'        # Python ssl.SSLContext bypass
    'ssl\.CERT_NONE'                                      # Python ssl.CERT_NONE
    'tls_verify[[:space:]]*=[[:space:]]*false'            # docker / podman config
    'CURL_INSECURE'                                       # curl env-var bypass
    'SSL_VERIFY=0'                                        # generic env-var bypass
    'PYTHONHTTPSVERIFY=0'                                 # Python stdlib bypass
    'DOCKER_TLS_VERIFY=0'                                 # docker daemon env bypass
    'allow_insecure'                                      # generic config flag
    'secure-http[[:space:]]+false'                        # composer config
    'pip[[:space:]]+install[^"]*--trusted-host'           # pip override
    "--tls-verify=false${_BOUNDARY}"                      # docker / podman
    "--no-tls${_BOUNDARY}"                                # misc clients
    'GIT_SSL_NO_VERIFY'                                   # git env bypass
    'http\.sslVerify[[:space:]]*=[[:space:]]*false'       # git -c http.sslVerify=false
    'NODE_TLS_REJECT_UNAUTHORIZED=0'                      # Node.js env bypass
    'NPM_CONFIG_STRICT_SSL=false'                         # npm env bypass
    'strict-ssl[[:space:]]*=[[:space:]]*false'            # .npmrc / pacman.conf
    'rejectUnauthorized[[:space:]]*:[[:space:]]*false'    # https.Agent / axios
    'InsecureSkipVerify'                                  # Go tls.Config field
)

# Build a single alternation from the array.
deny_pattern=$(IFS='|'; echo "(${deny_patterns[*]})")

# Restrict the sweep to executable file types. The recursive grep
# below uses --include globs; plain `Dockerfile` (no extension) is
# added explicitly because no glob would match it.
# Top-level compose*.yaml expands at glob time. `nullglob` keeps the
# script working in a checkout that happens to be missing one of
# them (e.g. partial worktree). Saved + restored locally so the
# global shell state is untouched.
shopt -q nullglob && _nullglob_was_set=1 || _nullglob_was_set=0
shopt -s nullglob
_compose_files=(compose*.yaml)
[ "$_nullglob_was_set" = "0" ] && shopt -u nullglob

hits=$(grep -rnE \
    --include='*.sh' \
    --include='*.py' \
    --include='*.yml' \
    --include='*.yaml' \
    --include='*.mk' \
    --include='Makefile' \
    --include='Dockerfile*' \
    --include='*.j2' \
    --exclude-dir='node_modules' \
    --exclude-dir='.git' \
    "$deny_pattern" \
    Makefile Make scripts installer rootfs setup tests .github Dockerfile \
    dev templates \
    "${_compose_files[@]}" \
    2>/dev/null || true)

# Drop self-references (this script + the lockstep test harness embed
# the deny patterns as literals). `|| true` because a grep that
# filters everything exits 1 under pipefail — "no surviving hits" is
# the success case.
hits=$(printf '%s\n' "$hits" \
    | { grep -vE '^(scripts/lockstep/check-tls-verify\.sh|tests/test-lockstep\.sh):|^$' || true; })

if [ -n "$hits" ]; then
    echo "::error::TLS-verify bypass detected in executable files. Remove the bypass — do NOT commit with an exception marker. Operator-facing debug techniques belong in docs/https-certs.md, not in code." >&2
    printf '%s\n' "$hits" >&2
    exit 1
fi

echo "  no TLS-verify bypass detected in executable files"
