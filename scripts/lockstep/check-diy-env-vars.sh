#!/usr/bin/env bash
# Asserts every environment variable named in `docs/diy.md` also
# appears in `docs/env-vars.md` (issue #126). The DIY doc claims
# the listed vars are the published-image contract; the env-vars doc
# is the authoritative inventory. Drift between the two means a DIY
# operator following diy.md hits an undocumented or stale variable.
#
# Scope: variable names from the DIY doc's contract tables. The DIY
# doc also references CLI flags (`--use-external-db`, `--db-data-path`)
# and image paths — those are out of scope here; only ALL_CAPS
# identifiers in `backtick markdown` get checked.
#
# Drift modes this catches:
#   * DIY doc adds `WEBTREES_NEW_KNOB` but env-vars.md doesn't list it.
#   * env-vars.md renames `MARIADB_PASSWORD` but diy.md still says the
#     old name.
#
# Failure-path test in `tests/test-lockstep.sh` injects a bogus var.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

[ -f docs/diy.md ] || {
    echo "::error::docs/diy.md not found" >&2
    exit 1
}
[ -f docs/env-vars.md ] || {
    echo "::error::docs/env-vars.md not found" >&2
    exit 1
}

# Allowlist: variables the DIY doc mentions that are NOT runtime env
# vars and therefore won't appear in env-vars.md. Keep this list
# short and named so a future addition is intentional.
#
# - FALSE / TRUE      literal values inline-coded in diy.md (e.g.
#                     `ENFORCE_HTTPS=FALSE`); look like an env var
#                     because of the screaming-snake convention but
#                     are values.
# - HEALTHCHECK       Docker directive name, not an env var.
# - CMD / CMD-SHELL   compose healthcheck `test:` array forms.
allowlist_regex='^(FALSE|TRUE|HEALTHCHECK|CMD|CMD-SHELL)$'

# Extract env-var names from two surfaces in docs/diy.md:
#   1. Backticked `IDENTIFIERS` in prose / tables.
#   2. YAML keys in the compose example (`^  *IDENTIFIER:`). The
#      compose example demonstrates the contract; if it references
#      a var that env-vars.md doesn't carry, the example will mislead.
#
# Filter to UPPER_ tokens ≥3 chars (avoids 2-char acronyms like OS).
# `sort -u` deduplicates between the two extraction modes when an
# env var appears in both surfaces.
# shellcheck disable=SC2016
# Backticks inside the regex are intentional markdown delimiters,
# not bash command substitution.
diy_backticked=$(grep -oE '`[A-Z][A-Z0-9_]{2,}`' docs/diy.md \
    | sed 's/`//g')
diy_yaml_keys=$(grep -oE '^[[:space:]]+[A-Z][A-Z0-9_]{2,}:' docs/diy.md \
    | sed -E 's/^[[:space:]]+//; s/:$//')
diy_vars=$(printf '%s\n%s\n' "$diy_backticked" "$diy_yaml_keys" \
    | grep -vE '^[[:space:]]*$' \
    | sort -u)

# Each line in env-vars.md's primary table starts with a backticked
# variable name; capture them the same way.
# shellcheck disable=SC2016
envdoc_vars=$(grep -oE '`[A-Z][A-Z0-9_]{2,}`' docs/env-vars.md \
    | sort -u \
    | sed 's/`//g')

missing=""
for v in $diy_vars; do
    # Skip allowlist entries.
    if [[ "$v" =~ $allowlist_regex ]]; then
        continue
    fi
    if ! grep -qFx "$v" <<<"$envdoc_vars"; then
        missing="$missing $v"
    fi
done

if [ -n "$missing" ]; then
    echo "::error::docs/diy.md references variables missing from docs/env-vars.md:$missing" >&2
    echo "::error::either add them to env-vars.md (preferred) or remove from diy.md." >&2
    exit 1
fi

count=$(printf '%s\n' "$diy_vars" | wc -l)
echo "  $count variables in docs/diy.md, all present in docs/env-vars.md"
