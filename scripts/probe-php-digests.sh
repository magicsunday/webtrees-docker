#!/usr/bin/env bash
# Probes the current multi-arch digest for every PHP minor tracked
# in dev/versions.json, compares against dev/php_digests.lock, and
# emits the rolling-tag-movement set as a workflow output.
#
# Unique to `.github/workflows/check-php.yml` because PHP is the
# only base image where the project tracks ROLLING-TAG mutations
# (patch-level digest changes) in addition to new-minor
# availability. Alpine/MariaDB/nginx only file an issue when a NEW
# minor lands; PHP triggers an automatic image rebuild the moment
# `php:X.Y-fpm-alpine` moves to a new digest under the same minor.
#
# Required env vars:
#   GITHUB_OUTPUT  Path to the GHA outputs file (set by every
#                  workflow step automatically — required so the
#                  caller can branch on `lockfile_dirty` /
#                  `changes`).
#
# Side effects:
#   * Writes `/tmp/new_digests` (consumed by the lockfile-update
#     step that follows in the same job).
#   * Emits `changes` (multi-line) + `lockfile_dirty=true` to
#     $GITHUB_OUTPUT when relevant.
#
# Exit codes:
#   0  Probe completed (possibly with no changes).
#   1  Hard failure: docker buildx imagetools inspect could not
#      read a digest for a tracked minor (Docker Hub outage, tag
#      removed upstream, daemon misconfigured). The caller's
#      `set -euo pipefail` propagates the exit code.

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT env var is required}"

# Pull every distinct PHP minor from versions.json.
versions=$(jq -r '.[].php' dev/versions.json | sort -u)
changes=""
: > /tmp/new_digests
for ver in $versions; do
    # docker buildx imagetools inspect emits a multi-arch index
    # digest; that's stable across architectures and is what we
    # want to detect rolling-tag movement.
    current=$(docker buildx imagetools inspect \
        "docker.io/library/php:${ver}-fpm-alpine" \
        --format '{{ .Manifest.Digest }}' 2>/dev/null)
    [ -n "$current" ] || { echo "::error::failed to read digest for php:${ver}-fpm-alpine"; exit 1; }
    echo "${ver}=${current}" >> /tmp/new_digests
    previous=$(grep "^${ver}=" dev/php_digests.lock 2>/dev/null | cut -d= -f2- || echo "")
    if [ -n "$previous" ] && [ "$current" != "$previous" ]; then
        changes="${changes}${ver} ($previous → $current)\n"
    elif [ -z "$previous" ]; then
        # New version present in versions.json but no baseline
        # digest yet. Seed the lockfile silently — do NOT dispatch
        # a rebuild. The corresponding minor-bump issue (filed by
        # the maintainer or by the scan-step below) is the place
        # to gate the human review.
        echo "Seeding new digest for ${ver} (no prior baseline)"
    fi
done
sort /tmp/new_digests > /tmp/new_digests.sorted
mv /tmp/new_digests.sorted /tmp/new_digests
if [ -n "$changes" ]; then
    {
        echo "changes<<EOF"
        printf '%b' "$changes"
        echo "EOF"
    } >> "$GITHUB_OUTPUT"
fi
if ! cmp -s /tmp/new_digests dev/php_digests.lock; then
    echo "lockfile_dirty=true" >> "$GITHUB_OUTPUT"
fi
