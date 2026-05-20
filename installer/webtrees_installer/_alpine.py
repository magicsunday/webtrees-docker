"""Single source of truth for the Alpine base-image tag.

Every consumer (port probe, admin-secret preseed, rendered compose
files) reads from this module. A future bump is one constant to edit;
the drift-check in `make ci-test` enforces that all references stay in
lockstep.

Pin policy: minor only, no patch. Alpine ships security fixes within
a minor — the `:X.Y` tag resolves to the latest patch on every pull.
Stepping the minor is a deliberate bump that catches breaking changes
from upstream. The minor-only shape is enforced by `make ci-alpine-lockstep`.
"""

from __future__ import annotations

import os


ALPINE_BASE_IMAGE = "alpine:3.23"


def get_helper_image() -> str:
    """Return the Docker image used for ephemeral helper containers.

    Ephemeral helper containers are short-lived ``docker run`` invocations
    that the installer uses internally (port-conflict probe, admin-password
    pre-seed).  They are distinct from the ``init`` service baked into the
    rendered ``compose.yaml``, which always stays at ``ALPINE_BASE_IMAGE``.

    The default is ``ALPINE_BASE_IMAGE`` (``alpine:3.23`` from Docker Hub).
    Set ``WEBTREES_HELPER_IMAGE`` to an already-pulled image reference to
    avoid a Docker Hub pull — useful in CI environments where the installer
    image itself (a Python/Alpine image from GHCR) is already available and
    Docker Hub unauthenticated rate limits may be exhausted by concurrent
    matrix jobs.

    The override image must supply ``sh``, ``cat``, ``chmod``, and ``true``.
    The webtrees-installer image satisfies all these requirements.
    """
    override = os.environ.get("WEBTREES_HELPER_IMAGE", "").strip()
    return override if override else ALPINE_BASE_IMAGE
