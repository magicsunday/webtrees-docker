#!/usr/bin/env bash
# Asserts every patch referenced from setup/composer-{core,full}-X.Y.json's
# `extra.patches."fisharebest/webtrees"` block applies cleanly against
# fisharebest/webtrees at the matching X.Y version range. Invoked by
# `make ci-patches-apply-lockstep`.
#
# Per webtrees version from dev/versions.json:
#   1. derive X.Y (the major.minor)
#   2. for the matching composer-core-X.Y.json AND composer-full-X.Y.json,
#      extract `extra.patches."fisharebest/webtrees"` paths
#   3. git clone fisharebest/webtrees at the exact version, run
#      `git apply --check` on every referenced patch
#
# Network-dependent — skipped when CHECK_PATCHES_APPLY=0 is set (the
# offline-CI escape hatch).

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

if [ "${CHECK_PATCHES_APPLY:-1}" = "0" ]; then
    echo "  CHECK_PATCHES_APPLY=0 — skipping patches-apply lockstep (offline mode)"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "::error::git not on PATH — required for patches-apply lockstep" >&2
    exit 1
fi

versions=$(ci_run_jq "$repo_root" \
    -r '[.[].webtrees] | unique | .[]' versions.json) || {
    echo "::error::failed to extract webtrees versions from dev/versions.json" >&2
    exit 1
}

[ -n "$versions" ] || {
    echo "::error::dev/versions.json carries no webtrees rows" >&2
    exit 1
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

failures=0
for version in $versions; do
    major_minor=${version%.*}
    src_dir="$tmp_root/webtrees-$version"
    echo "  checking patches against fisharebest/webtrees $version"

    # Collect the union of patch paths referenced by both manifests for
    # this version line. The composer-patches-lockstep guarantees the
    # two pairs carry identical patch sets so taking the union is
    # equivalent to reading either; the union form keeps this check
    # independent of that invariant.
    patches=()
    for variant in core full; do
        manifest="setup/composer-${variant}-${major_minor}.json"
        if [ ! -f "$manifest" ]; then
            echo "::error::missing $manifest (referenced by webtrees $version)" >&2
            failures=$((failures + 1))
            continue
        fi
        while IFS= read -r p; do
            [ -n "$p" ] && patches+=("$p")
        done < <(ci_run_jq_stdin -r '.extra.patches["fisharebest/webtrees"] // {} | values[]' < "$manifest")
    done

    # Drop duplicates.
    if [ "${#patches[@]}" -gt 0 ]; then
        mapfile -t patches < <(printf '%s\n' "${patches[@]}" | sort -u)
    fi

    if [ "${#patches[@]}" -eq 0 ]; then
        echo "  (no patches referenced for $version)"
        continue
    fi

    if ! git clone --quiet --depth=1 --branch "$version" \
            https://github.com/fisharebest/webtrees "$src_dir" >/dev/null 2>&1; then
        echo "::error::git clone failed for fisharebest/webtrees@$version" >&2
        failures=$((failures + 1))
        continue
    fi

    for patch in "${patches[@]}"; do
        patch_path="setup/${patch}"
        if [ ! -f "$patch_path" ]; then
            echo "::error::patch '$patch' referenced from composer manifest does not exist at $patch_path" >&2
            failures=$((failures + 1))
            continue
        fi
        patch_abs=$(cd "$repo_root" && pwd)/$patch_path
        if ! (cd "$src_dir" && git apply --check "$patch_abs") 2>/dev/null; then
            echo "::error::$patch_path does not apply cleanly to fisharebest/webtrees@$version" >&2
            failures=$((failures + 1))
        fi
    done
done

if [ "$failures" -gt 0 ]; then
    echo "::error::$failures patch/version pair(s) failed apply-check" >&2
    exit 1
fi

echo "  setup/patches/ applies cleanly to all $(printf '%s' "$versions" | wc -w) webtrees version(s)"
