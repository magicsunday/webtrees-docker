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


ALPINE_BASE_IMAGE = "alpine:3.23"
