#!/usr/bin/env bash
# Prints the currently-pinned MariaDB X.Y minor from the canonical
# site (`installer/webtrees_installer/templates/compose.standalone.j2`).
# Counterpart to `parse-alpine-pin.sh` and `parse-port-defaults.sh` —
# every drift-prone pin gets a named, shellcheck-covered extraction
# script so callers (cron workflows, lockstep tests) read the same
# source.
#
# Output: the X.Y minor on stdout (no newline beyond `echo`'s default),
# exit 0 on success.
# Exit 1 with an actionable `::error::` annotation if the canonical
# site cannot be parsed.

set -euo pipefail

repo_root=${1:-$(pwd)}
canonical="${repo_root}/installer/webtrees_installer/templates/compose.standalone.j2"

[ -f "$canonical" ] || {
    echo "::error::parse-mariadb-pin: canonical template missing at ${canonical}" >&2
    exit 1
}

# Anchor against the `image:` directive so a comment line carrying
# `mariadb:X.Y` (e.g. the BYOD bind-mount explainer) cannot be
# misread by `head -1`. The regex tolerates a trailing comment and
# rejects X.Y.Z patch-pinned variants — the rolling-minor pin is the
# project's contract. Symmetric with `_PIN_RE` in
# installer/tests/test_mariadb_pin_lockstep.py.
#
# `|| true` keeps the script alive under set -euo pipefail when grep
# finds zero matches, so the `[ -z … ]` guard can produce the
# actionable error instead of leaking a raw shell exit.
pinned_minor=$( { grep -hE '^\s*image:\s*mariadb:[0-9]+\.[0-9]+([[:space:]]|$)' "$canonical" || true; } \
    | head -1 \
    | sed -E 's|^\s*image:\s*mariadb:([0-9]+\.[0-9]+).*|\1|')

if [ -z "$pinned_minor" ]; then
    echo "::error::parse-mariadb-pin: could not parse the mariadb pin from compose.standalone.j2 — expected an 'image: mariadb:X.Y' line" >&2
    exit 1
fi

echo "$pinned_minor"
