#!/usr/bin/env bash
# Behaviour tests for the root operator launchers (`install`, `upgrade`,
# `switch`) and the build-flow helper `scripts/configuration` /
# `scripts/build/composer-*.sh` (GH-114 audit-loop).
#
# Two styles:
#   * Source-and-call for the pure helpers (apply_config_value,
#     validate_environment) so the escaping / validation contract is
#     pinned directly.
#   * End-to-end-with-stubs for `upgrade` and `switch`: a throwaway work
#     dir holds the .env / compose.yaml fixtures, a PATH-shimmed stub dir
#     mocks docker/curl, and a local `./install` stub records the exact
#     flags the launcher hands it — the only way to prove the .env parser
#     and the destructive-ordering / edition-persistence fixes.

set -o errexit -o nounset -o pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

pass=0
fail=0

work_root=$(mktemp -d /tmp/wt-launchers.XXXXXX)
trap 'rm -rf "$work_root"' EXIT

# assert_rc <name> <actual_rc> <expected_rc>  (used with assert_contains)
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ko() {
    echo "FAIL  $1"
    shift
    printf '      %s\n' "$@"
    fail=$((fail + 1))
}

# Assert rc matches AND each remaining arg is a literal substring of $out.
# $out is set by the caller before invoking.
check() {
    local name=$1 rc=$2 want_rc=$3
    shift 3
    if [ "$rc" != "$want_rc" ]; then
        ko "$name" "expected rc=$want_rc, got rc=$rc" "output:" "$(printf '%s\n' "$out" | tail -4)"
        return
    fi
    local needle
    for needle in "$@"; do
        if ! grep -qF -- "$needle" <<<"$out"; then
            ko "$name" "missing substring: $needle" "output:" "$(printf '%s\n' "$out" | tail -6)"
            return
        fi
    done
    ok "$name"
}

# Assert a literal substring is ABSENT from $out (rc must match too).
check_absent() {
    local name=$1 rc=$2 want_rc=$3 needle=$4
    if [ "$rc" != "$want_rc" ]; then
        ko "$name" "expected rc=$want_rc, got rc=$rc"
        return
    fi
    if grep -qF -- "$needle" <<<"$out"; then
        ko "$name" "unexpected substring present: $needle" "output:" "$(printf '%s\n' "$out" | tail -6)"
        return
    fi
    ok "$name"
}

# ──────────────────────────────────────────────────────────────────────
# scripts/configuration: apply_config_value sed-escaping (GH-114 A)
# ──────────────────────────────────────────────────────────────────────

# A password carrying every sed-hostile byte (`/`, `&`, `\`) must be
# written literally, exit 0 — the old raw interpolation aborted sed with
# `unknown option to 's'` (non-zero under errexit) and half-seeded the
# config.
out=$(HOSTILE='p/a&s\s' bash -c '
    source "'"$repo_root"'/scripts/configuration"
    f=$(mktemp)
    printf "dbpass=\"OLD\";\n" > "$f"
    apply_config_value dbpass "$HOSTILE" "$f"
    cat "$f"
    rm -f "$f"
' 2>&1) && rc=0 || rc=$?
check "configuration: apply_config_value escapes / & \\ literally" "$rc" 0 \
    'dbpass="p/a&s\s";'

# The anchored LHS must not over-match a different line that merely shares
# the key as a suffix/substring: rewriting `dbname` must leave `mydbname`
# untouched.
out=$(bash -c '
    source "'"$repo_root"'/scripts/configuration"
    f=$(mktemp)
    printf "mydbname=\"KEEP\";\ndbname=\"OLD\";\n" > "$f"
    apply_config_value dbname NEW "$f"
    cat "$f"
    rm -f "$f"
' 2>&1) && rc=0 || rc=$?
check "configuration: apply_config_value anchors the key (no suffix collision)" "$rc" 0 \
    'mydbname="KEEP";' 'dbname="NEW";'

# An ampersand-only value must not expand to the whole match.
out=$(HOSTILE='a&b' bash -c '
    source "'"$repo_root"'/scripts/configuration"
    f=$(mktemp)
    printf "dbuser=\"OLD\";\n" > "$f"
    apply_config_value dbuser "$HOSTILE" "$f"
    cat "$f"
    rm -f "$f"
' 2>&1) && rc=0 || rc=$?
check "configuration: apply_config_value does not expand & to the match" "$rc" 0 \
    'dbuser="a&b";'

# ──────────────────────────────────────────────────────────────────────
# scripts/configuration: validate_environment required vars (GH-114 B)
# ──────────────────────────────────────────────────────────────────────

# WEBTREES_TABLE_PREFIX / WEBTREES_REWRITE_URLS are consumed under
# nounset; with one unset, validate must emit the clean log_error + exit 1
# instead of a raw "unbound variable" abort later.
out=$(bash -c '
    source "'"$repo_root"'/scripts/configuration"
    APP_DIR=x MARIADB_HOST=x MARIADB_PORT=3306 MARIADB_USER=x \
    MARIADB_PASSWORD=x MARIADB_DATABASE=x DEV_DOMAIN=x ENFORCE_HTTPS=FALSE \
    WEBTREES_REWRITE_URLS=1 \
    validate_environment
' 2>&1) && rc=0 || rc=$?
check "configuration: validate_environment flags missing WEBTREES_TABLE_PREFIX" "$rc" 1 \
    "Required environment variable WEBTREES_TABLE_PREFIX is not set"

# ──────────────────────────────────────────────────────────────────────
# scripts/build/composer-{install,update}.sh: APP_DIR guard (GH-114 D)
# ──────────────────────────────────────────────────────────────────────

# With APP_DIR unset the guard must fail with the actionable message, not
# the raw `APP_DIR: unbound variable` the bare nounset reference produced.
for script in composer-install.sh composer-update.sh; do
    out=$(unset APP_DIR; "$repo_root/scripts/build/$script" 2>&1) && rc=0 || rc=$?
    check "build/$script: APP_DIR guard fails with a clear message" "$rc" 1 \
        "APP_DIR must be set by the build environment"
done

# ──────────────────────────────────────────────────────────────────────
# upgrade: fetch-before-destroy ordering (GH-114 C)
# ──────────────────────────────────────────────────────────────────────

# Helper: build a throwaway work dir with a stub dir on PATH. Echoes the
# work dir path.
new_workdir() {
    local d
    d=$(mktemp -d "$work_root/wd.XXXXXX")
    mkdir -p "$d/stub"
    echo "$d"
}

stub_into() {
    # stub_into <dir> <name> <body>
    local dir=$1 name=$2 body=$3
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$dir/$name"
}

# Failing fetch must abort BEFORE any docker call — no volume rm.
wd=$(new_workdir)
: > "$wd/compose.yaml"
echo "" > "$wd/docker_calls.log"
stub_into "$wd/stub" docker "echo \"\$*\" >> '$wd/docker_calls.log'"
stub_into "$wd/stub" curl 'exit 22'   # transient network failure
out=$(cd "$wd" && PATH="$wd/stub:$PATH" INSTALLER_REMOTE='https://example/install' \
    "$repo_root/upgrade" 2>&1) && rc=0 || rc=$?
check "upgrade: failed fetch aborts with an intact-stack message" "$rc" 1 \
    "aborting before touching any volume"
out=$(cat "$wd/docker_calls.log")
check_absent "upgrade: failed fetch never reaches 'docker volume rm'" 0 0 "volume rm"

# Happy path: fetch succeeds, THEN down + volume rm, THEN the fetched
# script runs.
wd=$(new_workdir)
: > "$wd/compose.yaml"
echo "" > "$wd/docker_calls.log"
stub_into "$wd/stub" docker "echo \"\$*\" >> '$wd/docker_calls.log'"
# curl -o <file>: write a harmless installer that proves it ran.
# shellcheck disable=SC2016
# $#/$1/$2/$out are the stub's OWN runtime positional args, not values to
# expand when the stub body is written.
stub_into "$wd/stub" curl 'out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done; printf "echo INSTALL_RAN\n" > "$out"'
out=$(cd "$wd" && PATH="$wd/stub:$PATH" INSTALLER_REMOTE='https://example/install' \
    "$repo_root/upgrade" 2>&1) && rc=0 || rc=$?
check "upgrade: happy path runs the fetched installer" "$rc" 0 "INSTALL_RAN"
out=$(cat "$wd/docker_calls.log")
check "upgrade: happy path does drop the app volume" 0 0 "volume rm"

# Fetch succeeds but `docker compose down` fails → errexit aborts BEFORE
# the destructive volume rm, leaving the app volume intact.
wd=$(new_workdir)
: > "$wd/compose.yaml"
echo "" > "$wd/docker_calls.log"
# shellcheck disable=SC2016
# $*/$1/$2/$#/$out below are the stubs' OWN runtime args; only $wd is
# interpolated (via the concatenated double-quoted segment).
stub_into "$wd/stub" docker 'echo "$*" >> '"$wd"'/docker_calls.log; if [ "$1" = compose ] && [ "$2" = down ]; then exit 1; fi; exit 0'
# shellcheck disable=SC2016
stub_into "$wd/stub" curl 'out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done; printf "echo INSTALL_RAN\n" > "$out"'
out=$(cd "$wd" && PATH="$wd/stub:$PATH" INSTALLER_REMOTE='https://example/install' \
    "$repo_root/upgrade" 2>&1) && rc=0 || rc=$?
check "upgrade: compose-down failure aborts the run" "$rc" 1
out=$(cat "$wd/docker_calls.log")
check_absent "upgrade: down failure never reaches 'docker volume rm'" 0 0 "volume rm"

# ──────────────────────────────────────────────────────────────────────
# switch: env_value parser parity + edition persistence (GH-114 E, F)
# ──────────────────────────────────────────────────────────────────────

# Build a standalone work dir whose ./install stub echoes its flags.
# `switch dev` (current=standalone) hands the dev install the snapshotted
# .env values, so the recorded flags reveal exactly what env_value parsed.
switch_dev_flags() {
    # switch_dev_flags <env-file-contents>  -> echoes the install flag line
    local env_contents=$1 wd
    wd=$(new_workdir)
    printf '%s' "$env_contents" > "$wd/.env"
    : > "$wd/compose.yaml"
    : > "$wd/Dockerfile"   # dev mode requires a webtrees-docker clone
    stub_into "$wd/stub" docker ':'
    # The launcher calls ./install (relative); the exec'd stub prints flags.
    stub_into "$wd" install 'echo "$*"'
    (cd "$wd" && PATH="$wd/stub:$PATH" "$repo_root/switch" dev 2>&1)
}

# CRLF .env value: the CR must be stripped (old tr -d '"' left it in,
# diverging from the wizard's .strip()).
out=$(switch_dev_flags $'MARIADB_USER=myuser\r\nMARIADB_PASSWORD=secret\n') && rc=0 || rc=$?
check "switch: env_value strips a trailing CR from CRLF .env values" "$rc" 0 \
    "--mariadb-user myuser --mariadb-password secret"

# A surrounding quote pair is stripped; an inner slash is preserved
# (old tr -d '\"' would also have mangled nothing here but the new parser
# must keep the inner / intact).
out=$(switch_dev_flags $'MARIADB_PASSWORD="se/cret"\n') && rc=0 || rc=$?
check "switch: env_value strips wrapping quotes, keeps inner slash" "$rc" 0 \
    "--mariadb-password se/cret"

# `export KEY=` and spaced `KEY = value` forms must parse (old anchor
# `^KEY=` silently dropped both → wrong default).
out=$(switch_dev_flags $'export APP_PORT=39999\nMARIADB_USER = customuser\n') && rc=0 || rc=$?
check "switch: env_value tolerates export-prefix and spaced equals" "$rc" 0 \
    "--port 39999" "--mariadb-user customuser"

# Edition persistence (F): a standalone .env with EDITION=core must NOT be
# re-rendered onto full when switching to dev.
out=$(switch_dev_flags $'EDITION=core\n') && rc=0 || rc=$?
check "switch: dev install inherits the persisted edition (core)" "$rc" 0 \
    "--edition core"

# An empty persisted EDITION must fall back to the `full` default — never
# reach `./install --edition ""`, which argparse rejects AFTER teardown.
out=$(switch_dev_flags $'EDITION=\n') && rc=0 || rc=$?
check "switch: empty EDITION falls back to --edition full" "$rc" 0 "--edition full"

# A garbage (non-core/full) persisted token is coerced to full, not passed
# verbatim (which argparse would reject with exit 2 after `compose down`).
out=$(switch_dev_flags $'EDITION=nonsense\n') && rc=0 || rc=$?
check "switch: invalid EDITION token coerced to full" "$rc" 0 "--edition full"
check_absent "switch: invalid EDITION not passed verbatim" 0 0 "--edition nonsense"

# The headline regression: a CORE dev install switched back to standalone
# must restore core, not the hard-coded full.
wd=$(new_workdir)
printf 'ENVIRONMENT=development\nEDITION=core\nAPP_PORT=28080\n' > "$wd/.env"
: > "$wd/compose.yaml"
stub_into "$wd/stub" docker ':'
stub_into "$wd" install 'echo "$*"'
out=$(cd "$wd" && PATH="$wd/stub:$PATH" "$repo_root/switch" standalone 2>&1) && rc=0 || rc=$?
check "switch: dev(core)->standalone restores --edition core (not full)" "$rc" 0 \
    "--edition core"
check_absent "switch: dev(core)->standalone does not force --edition full" 0 0 "--edition full"

# A trailing-space ENVIRONMENT marker must still be read as dev mode, so a
# dev->standalone switch is not misread as a no-op.
wd=$(new_workdir)
printf 'ENVIRONMENT=development \nEDITION=full\n' > "$wd/.env"
: > "$wd/compose.yaml"
stub_into "$wd/stub" docker ':'
stub_into "$wd" install 'echo "switched=$*"'
out=$(cd "$wd" && PATH="$wd/stub:$PATH" "$repo_root/switch" standalone 2>&1) && rc=0 || rc=$?
check "switch: trailing-space ENVIRONMENT marker still detected as dev" "$rc" 0 "switched="
check_absent "switch: trailing-space marker not misread as already-standalone" 0 0 \
    "Already in standalone mode"

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
