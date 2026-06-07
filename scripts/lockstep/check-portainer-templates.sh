#!/usr/bin/env bash
# Asserts the committed templates/portainer/{compose.yaml,.env.example}
# are byte-identical to a fresh render of the Jinja sources at
# installer/webtrees_installer/templates/. Invoked by
# `make ci-portainer-templates-lockstep`.
#
# Drift mode this catches: any edit to the Jinja sources (e.g. tightening
# the secrets `chmod` idiom, bumping a healthcheck, adjusting a comment)
# leaves the pre-rendered Portainer artefacts stale until someone manually
# runs `make portainer-templates`. The lockstep makes that pairing
# mandatory by failing CI when the committed files diverge from a fresh
# render.
#
# The render is deterministic: scripts/render-portainer-templates.sh
# pins generated_at to a fixed sentinel and sed-strips the timestamp
# comment in .env.example so re-runs produce byte-stable output.
#
# Side-effect-free by design: WEBTREES_INSTALLER_RENDER_OUT redirects the
# renderer into our $stage tempdir so the committed files are never
# touched, regardless of outcome. No backup/restore choreography, no
# mtime bumps on clean runs, no race when invoked concurrently.
#
# Network-dependent because the render uses `pip install` inside a
# docker container — skipped when CHECK_PORTAINER_TEMPLATES=0 is set
# (the offline-CI escape hatch).

# shellcheck source=scripts/lib/lockstep.sh
source "$(dirname "$0")/../lib/lockstep.sh"
lockstep_init "$@"

if [ "${CHECK_PORTAINER_TEMPLATES:-1}" = "0" ]; then
    echo "  CHECK_PORTAINER_TEMPLATES=0 — skipping portainer-templates lockstep (offline mode)" >&2
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "::error::docker required for portainer-templates lockstep" >&2
    exit 1
fi

# System $TMPDIR (mktemp -t) so a SIGKILL-leaked stage tempdir never
# pollutes the worktree.
stage=$(mktemp -d -t portainer-lockstep.XXXXXX)
trap 'rm -rf "$stage"' EXIT INT TERM HUP

# Render directly into $stage; the committed templates/portainer/ files
# are never written to, so there is nothing to restore and no mtime to
# bump on clean runs.
if ! WEBTREES_INSTALLER_RENDER_OUT="$stage" \
    ./scripts/render-portainer-templates.sh >"$stage/render.log" 2>&1; then
    echo "::error::render-portainer-templates.sh failed:" >&2
    cat "$stage/render.log" >&2
    exit 1
fi

failures=0
if ! diff -u templates/portainer/compose.yaml "$stage/compose.yaml" >"$stage/compose.diff"; then
    echo "::error::templates/portainer/compose.yaml drifts from a fresh render:" >&2
    cat "$stage/compose.diff" >&2
    failures=$((failures + 1))
fi

if ! diff -u templates/portainer/.env.example "$stage/.env.example" >"$stage/env.diff"; then
    echo "::error::templates/portainer/.env.example drifts from a fresh render:" >&2
    cat "$stage/env.diff" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    echo "::error::templates/portainer/ is out of sync with the installer Jinja sources" >&2
    echo "Run \`make portainer-templates\` and commit the result." >&2
    exit 1
fi

echo "  templates/portainer/{compose.yaml,.env.example} mirror a fresh render"
