#!/usr/bin/env bash
# Renders `make help` output by parsing `## docstrings` from every
# loaded Makefile/.mk file. Invoked by `Make/helper/help.mk`'s `help`
# recipe with the Makefile-list passed in as argv.
#
# Inputs:
#   $@ — list of Makefile fragments (output of `$(filter-out %.env,
#        $(MAKEFILE_LIST))` from the calling recipe)
#
# Inputs (env):
#   FYELLOW, FGREEN, FRESET — colour escape sequences from the
#       caller's `tput` block (Makefile root). Empty strings if TERM
#       is unset (CI logs / piped output stay plain).
#
# Output:
#
#       Usage:
#         make [target] ...
#
#       <section header>
#         <target>          <description>
#
#   Section headers come from `^#### ` lines in the .mk files;
#   targets come from `^<name>:.*##` lines.
#
# Column-split design:
#   The TAB byte (not `##`) separates target name from description so
#   `#` characters inside descriptions — `$(CI_IMAGE_X)` Make-var
#   refs, parenthesised issue numbers — pass through `column -t -s`
#   unchanged. `column` collapses blank input lines, so an awk
#   post-processor re-injects them before each section header.

set -euo pipefail

[ "$#" -ge 1 ] || {
    echo "::error::render-make-help.sh requires at least one Makefile argument" >&2
    exit 1
}

# Color env vars (set by the calling Makefile via tput; empty when
# TERM is unset). Quote-default to empty so `set -u` doesn't blow up
# when a caller forgets to export them.
FYELLOW=${FYELLOW:-}
FGREEN=${FGREEN:-}
FRESET=${FRESET:-}

printf '%sUsage:%s\n  make [target] ...\n' "$FYELLOW" "$FRESET"

# Step 1: grep target + section-header lines from every Makefile.
# Step 2: strip line-continuation backslashes and the .logo
#         prerequisite hint (operators don't need to know).
# Step 3: rewrite section headers (`#### Foo` → coloured Foo).
# Step 4: rewrite target lines (`name: deps ## desc` → green name +
#         literal TAB + description). The TAB is the column-split
#         marker — using it instead of `##` means descriptions
#         containing `#` (issue refs, Make var refs) survive.
# Step 5: column-align two-column rows on the TAB separator.
# Step 6: awk-inject a blank line before each section header for
#         visual grouping (`column` collapses blank input lines).
cat -- "$@" 2>/dev/null \
    | grep -E '(^[a-zA-Z0-9._-]+:.*##|^#### )' \
    | sed -e 's/\\$//' \
          -e 's/ \.logo//g' \
    | sed -E "s/^#### (.+)$/__SECTION__${FYELLOW}\1${FRESET}/" \
    | sed -E "s/^([a-zA-Z0-9._-]+):[^#]*## *(.*)$/  ${FGREEN}\1${FRESET}\t\2/" \
    | column -t -s "$(printf '\t')" \
    | awk -v sentinel='__SECTION__' '
        $0 ~ "^" sentinel { sub(sentinel, ""); print ""; print; next }
        { print }
      '

echo ""
