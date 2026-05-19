#!/usr/bin/env bash
# Asserts the four per-version composer manifests (setup/composer-{core,full}-{2.1,2.2}.json)
# agree on every key OUTSIDE the documented divergence set:
#   * `name`                                  — core vs full differ
#   * `description`                           — core vs full differ
#   * `require["fisharebest/webtrees"]`       — `~2.1.0` vs `~2.2.0`
#   * `require["magicsunday/webtrees-*"]`     — full carries chart deps, core does not
#   * `config.allow-plugins[*]`               — version-line-specific (2.1 enables the
#                                               installer-plugin, 2.2 disables it)
#   * `extra.patches`                         — 2.2 carries the VendorModuleService entry
#
# Everything else (authors, license, type, sort-packages, preferred-install, …)
# MUST match byte-for-byte across all four manifests. Invoked by
# `make ci-composer-patches-lockstep`.

set -euo pipefail

repo_root=${1:-$(pwd)}
cd "$repo_root"

# shellcheck source=scripts/lib/images.env
source "$(dirname "$0")/../lib/images.env"

manifests=(
    setup/composer-core-2.1.json
    setup/composer-core-2.2.json
    setup/composer-full-2.1.json
    setup/composer-full-2.2.json
)

for f in "${manifests[@]}"; do
    [ -f "$f" ] || { echo "::error::$f is missing" >&2; exit 1; }
done

# Strip the documented-divergence keys from each manifest and assert
# everything else is byte-identical.
strip_divergent='
    del(.name)
    | del(.description)
    | del(.require["fisharebest/webtrees"])
    | del(.require["magicsunday/webtrees-fan-chart"])
    | del(.require["magicsunday/webtrees-pedigree-chart"])
    | del(.require["magicsunday/webtrees-descendants-chart"])
    | del(.config["allow-plugins"]["magicsunday/webtrees-module-installer-plugin"])
    | del(.extra.patches)
'

baseline=""
for f in "${manifests[@]}"; do
    stripped=$(ci_run_jq_stdin -S -c "$strip_divergent" < "$f") || {
        echo "::error::docker run for $f strip failed" >&2
        exit 1
    }
    if [ -z "$baseline" ]; then
        baseline=$stripped
        continue
    fi
    if [ "$stripped" != "$baseline" ]; then
        echo "::error::$f diverges from the manifest baseline outside the documented-divergence keys" >&2
        echo "  baseline (from ${manifests[0]}): $baseline" >&2
        echo "  this file: $stripped" >&2
        exit 1
    fi
done

# Within each version line: core and full MUST carry identical
# extra.patches blocks (a patch added to one but not the other is the
# original drift class this check was added for).
for version in 2.1 2.2; do
    core_patches=$(ci_run_jq_stdin -S -c '.extra.patches // {}' < "setup/composer-core-${version}.json")
    full_patches=$(ci_run_jq_stdin -S -c '.extra.patches // {}' < "setup/composer-full-${version}.json")
    if [ "$core_patches" != "$full_patches" ]; then
        echo "::error::setup/composer-core-${version}.json and setup/composer-full-${version}.json carry divergent extra.patches blocks" >&2
        echo "  core: $core_patches" >&2
        echo "  full: $full_patches" >&2
        exit 1
    fi
done

echo "  setup/ composer manifests agree on shared keys; per-version core/full pairs carry identical patches"
