"""Source of truth for the Alpine pin + helper-image override.

Two related concerns live here so a future bump only needs one edit:

* `ALPINE_BASE_IMAGE` — the canonical Alpine tag baked into rendered
  compose files (init service). End users always see this tag in the
  compose.yaml the wizard emits.
* `get_helper_image()` / `HELPER_IMAGE_ENV_VAR` — the override hook
  for the two short-lived wizard helpers (port probe in `ports.py`,
  admin-password seed in `flow.py`). They run inside the wizard
  process and never touch the rendered compose file, so they can be
  redirected to an already-pulled image (e.g. the installer image
  itself in CI) to dodge Docker Hub's anonymous-pull quota.

Pin policy for `ALPINE_BASE_IMAGE`: minor only, no patch. Alpine ships
security fixes within a minor — the `:X.Y` tag resolves to the latest
patch on every pull. Stepping the minor is a deliberate bump that
catches breaking changes from upstream. The minor-only shape is
enforced by `make ci-alpine-lockstep`.
"""

from __future__ import annotations

import os


ALPINE_BASE_IMAGE = "alpine:3.24"


# The smoke-test matrix issues 40+ concurrent helper pulls from the same
# GHA runner IP pool, which exhausts Docker Hub's 100-pull/6h
# unauthenticated quota. Callers that already have a non-Hub image
# locally (e.g. the installer image pulled from GHCR) can set
# WEBTREES_HELPER_IMAGE to re-use it for the two short-lived helper
# operations (port-conflict probe and admin-password pre-seed). The
# rendered compose.yaml init service is NOT covered — it ships the
# canonical Alpine tag to end users regardless of this override.
HELPER_IMAGE_ENV_VAR = "WEBTREES_HELPER_IMAGE"


def get_helper_image() -> str:
    """Return the image to use for the port-probe and admin-seed helpers.

    Resolves WEBTREES_HELPER_IMAGE at call time so test fixtures and
    parent-process exports both flow through. Whitespace-only values
    are treated as unset; the empty string also falls back to alpine.
    """
    override = os.environ.get(HELPER_IMAGE_ENV_VAR, "").strip()
    return override or ALPINE_BASE_IMAGE
