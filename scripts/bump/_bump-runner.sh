# =============================================================================
# Shared docker-run launcher for the pin-bump operator scripts.
# =============================================================================
#
# bump-mariadb.sh and bump-nginx.sh were byte-twins around a single
# `docker run … python3 scripts/bump/bump-<x>.py "$@"` invocation. This
# lib carries that shared invocation once; each wrapper sources it and
# calls `bump_run` with its own Python implementation path. The python
# image is the central CI_IMAGE_PYTHON pin from scripts/lib/images.env,
# not a hardcoded literal, so an image bump is one edit.
#
# Usage from a wrapper:
#   # shellcheck source=scripts/bump/_bump-runner.sh
#   source "$(dirname "$0")/_bump-runner.sh"
#   bump_run scripts/bump/bump-<x>.py "$@"
#
# Why a script wrapper instead of pure Make: routing argv straight to
# the container dodges Make entirely — no $(shell …)/:=/!=/CURDIR=
# command-line overrides to guard. Make 4.4+ evaluates such command-line
# assignments at parse time and no in-Makefile guard can defeat them, so
# this script form is recommended whenever the invocation came from an
# untrusted source (chat, README, gist). Make's bump-* targets delegate
# here too, so operators may use either entry point.
#
# `--user $(id -u):$(id -g)` makes container-side mutations inherit the
# operator's UID/GID. Without it, every sed'd mirror site would land
# owned by root:root on the NAS host, blocking `git add` without sudo.

# shellcheck source=scripts/lib/images.env
source "$(dirname "${BASH_SOURCE[0]}")/../lib/images.env"

# Run a bump implementation inside the pinned python container.
#
# $1                  Repo-relative path of the Python bump script.
# remaining arguments Forwarded verbatim to that script.
#
# Mounts the repo root (resolved from this lib's own location, two
# levels up from scripts/bump/) at /app so the bump reads its templates
# and the .py loads. Replaces the calling shell via `exec`.
bump_run() {
    local impl=$1
    shift

    local repo_root
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

    exec docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "$repo_root:/app" \
        -w /app \
        "$CI_IMAGE_PYTHON" \
        python3 "$impl" "$@"
}
