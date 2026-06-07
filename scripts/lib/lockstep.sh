# =============================================================================
# Shared entry-preamble + JSON-parseability assertion for scripts/lockstep/.
# =============================================================================
#
# Every check-*.sh under scripts/lockstep/ (and parse-mariadb-pin.sh) opens
# with the same contract: `$1` is the repo root (default `$(pwd)`), the shell
# runs under `set -euo pipefail`, and the canonical dev/*.json sources are
# parsed through the `ci_run_jq` wrapper from images.env. This lib carries
# that cradle so a policy change — explicit-`$1` enforcement, `realpath`
# canonicalisation, a switch to `pushd` for recoverable failures — is one
# edit instead of touching every consumer.
#
# Sourcing this lib:
#   * turns on `set -euo pipefail` in the caller,
#   * pulls in scripts/lib/images.env so `ci_run_jq` is in scope (callers get
#     one include, not two),
#   * exposes `lockstep_init` and `assert_jq_parseable`.
#
# Usage in a script:
#   # shellcheck source=scripts/lib/lockstep.sh
#   source "$(dirname "$0")/../lib/lockstep.sh"
#   lockstep_init "$@"                          # sets $repo_root and cd's in
#   assert_jq_parseable "$repo_root" versions.json

set -euo pipefail

# Idempotent source guard: re-running the `readonly` below on a second
# source of this lib in the same shell would abort with `readonly variable`
# under `set -e`, so bail out early. Mirrors the guard in php-versions-lib.sh.
[ -n "${CI_LOCKSTEP_LIB:-}" ] && return 0 2>/dev/null || true
readonly CI_LOCKSTEP_LIB=1

# Pull in the shared ci_run_jq / CI_IMAGE_* cradle. Resolved off BASH_SOURCE
# (this file's own path) rather than `$0`, so the include works regardless of
# the caller's `$0` shape or current directory.
# shellcheck source=scripts/lib/images.env
source "$(dirname "${BASH_SOURCE[0]}")/images.env"

# Consolidates the repo-root entry-preamble: `$1` is the repo root (default
# the current directory), set as the global `repo_root` for the caller and
# cd'd into. Silent on stdout so parser scripts that emit a single value
# (e.g. parse-mariadb-pin.sh) stay clean.
#
# `repo_root` is canonicalised to its ABSOLUTE form (cd, then re-read via
# pwd) before it is handed back. This is load-bearing: consumers pass
# `$repo_root` straight into `ci_run_jq "$repo_root"`, which docker-mounts
# `${repo_root}/dev` — and a docker `-v` source is resolved against the
# original cwd, NOT the one we just cd'd into. Without canonicalisation a
# relative `$1` would double-prefix the mount (and any `${repo_root}/…` file
# read) after the cd. The cd runs first so a bad `$1` still fails loud under
# `set -e` before pwd is read.
#
# Call as `lockstep_init "$@"` so the script's own positional args reach the
# helper unchanged.
lockstep_init() {
    repo_root=${1:-$(pwd)}
    # `>/dev/null` suppresses the path echo `cd` emits to stdout when it
    # resolves a relative target via an exported CDPATH — otherwise that echo
    # would pollute the single-value stdout of parser consumers (e.g.
    # parse-mariadb-pin.sh). cd's failure still goes to stderr and still
    # aborts under set -e.
    cd "$repo_root" >/dev/null
    repo_root=$(pwd)
}

# Asserts a dev/<file> parses as JSON via ci_run_jq, exiting 1 with an
# actionable `::error::` annotation otherwise. Consolidates the 8+ open-coded
# `ci_run_jq … empty <file> >/dev/null 2>&1 || { echo "::error::…"; exit 1; }`
# probes scattered across the checkers.
#
# Unlike the open-coded form — which swallowed jq's diagnostic with
# `>/dev/null 2>&1` — this attaches jq's own stderr (newlines folded to keep
# the annotation single-line) so the operator sees WHERE the file is broken,
# not just THAT it is.
#
# The `dev/` prefix is hard-coded because ci_run_jq mounts `<repo>/dev` as its
# working directory, so callers pass the bare basename (e.g. `versions.json`).
#
# Callers MUST have sourced this lib (which pulls in images.env) so ci_run_jq
# is in scope.
assert_jq_parseable() {
    local repo_root=$1 file=$2 err
    if ! err=$(ci_run_jq "$repo_root" empty "$file" 2>&1 >/dev/null); then
        echo "::error::dev/${file} is not parseable JSON: ${err//$'\n'/ }" >&2
        exit 1
    fi
}

# Print the first assignment line for a top-level Python constant <symbol>
# in <file>, tolerating leading indentation and an optional `: Type`
# annotation between the name and the `=` (e.g. `X = 1`, `X: int = 1`,
# `    X: Final[str] = "…"`). The whole matched line is emitted so the
# caller applies its own value extraction (a quoted-string sed, an
# integer sed, …) against a known assignment shape.
#
# Empty stdout (no such constant found) is passed through rather than
# failing: the trailing `|| true` swallows grep's no-match exit so the
# caller's own emptiness check raises the actionable `::error::` instead
# of `set -e` aborting with no diagnostic. Consolidates the shared anchor
# regex of parse-alpine-pin.sh and parse-port-defaults.sh.
parse_python_constant() {
    local file=$1 symbol=$2
    grep -E "^[[:space:]]*${symbol}([[:space:]]*:[^=]+)?[[:space:]]*=" "$file" \
        | head -n 1 \
        || true
}
