"""Live port-conflict probe via a short-lived helper container.

The image is resolved through `_alpine.get_helper_image()` so the
wizard can be pointed at an already-pulled image (e.g. the installer
image itself in CI) instead of always pulling Alpine.
"""

from __future__ import annotations

import enum
import subprocess

from webtrees_installer._alpine import get_helper_image


# Public knob: callers can pass `timeout_s=PROBE_TIMEOUT_S * 2` or similar
# to scale the deadline relative to the default without hardcoding seconds.
#
# Sized to cover a cold `--pull=missing` of the helper image, not just a
# warm container start: the port probe is the FIRST helper `docker run` in
# the wizard flow, so it — not the later admin-password seed — pays the
# one-time image pull. A custom WEBTREES_HELPER_IMAGE may be far larger
# than the Alpine pin, so the budget matches the seed's pull-inclusive
# deadline rather than an Alpine-sized one. CI and the launcher pre-pull
# the image, making this a safety margin rather than the common path.
PROBE_TIMEOUT_S = 30

# Phrases the Docker daemon emits when the requested host port is occupied.
# Matched case-insensitively. Linux (`bind: address already in use`), Docker
# Desktop on macOS / Windows (`Ports are not available`) and the older
# userland-proxy stack (`port is already allocated`) all surface here.
_IN_USE_PHRASES: tuple[str, ...] = (
    "address already in use",
    "port is already allocated",
    "ports are not available",
)


class PortStatus(enum.Enum):
    """Result of a probe_port() call."""

    FREE = "free"
    IN_USE = "in_use"
    CHECK_FAILED = "check_failed"


def probe_port(port: int, *, timeout_s: float | None = None) -> PortStatus:
    """Try to bind `port` on the host via a short-lived helper container.

    Args:
        port: Host TCP port in the range ``1..65535``.
        timeout_s: Override for the subprocess deadline. ``None`` keeps the
            module default (``PROBE_TIMEOUT_S``); raise it for slow runners
            that may need to pull the helper image on first invocation.

    Returns:
        ``PortStatus.FREE`` if docker bound the port successfully,
        ``PortStatus.IN_USE`` if the daemon reported the port taken (any of
        the known phrasings — Linux, Desktop, userland-proxy), and
        ``PortStatus.CHECK_FAILED`` for everything else (missing CLI,
        timeout, permission errors, unrecognised stderr). Out-of-range
        ``port`` raises ``ValueError``.
    """
    if not 1 <= port <= 65535:
        raise ValueError(f"port out of range: {port}")

    effective_timeout = PROBE_TIMEOUT_S if timeout_s is None else timeout_s
    try:
        result = _run_docker_probe(port, timeout_s=effective_timeout)
    except (OSError, subprocess.TimeoutExpired):
        # Broadest OS-layer band: PermissionError (socket EACCES),
        # ConnectionRefusedError (remote docker context, dead daemon),
        # FileNotFoundError (docker binary missing). The caller treats
        # CHECK_FAILED as "warn and proceed", so collapsing all
        # OS-layer failures here keeps the docstring's promise of
        # graceful degradation.
        return PortStatus.CHECK_FAILED

    if result.returncode == 0:
        return PortStatus.FREE
    stderr_lower = (result.stderr or "").lower()
    if any(phrase in stderr_lower for phrase in _IN_USE_PHRASES):
        return PortStatus.IN_USE
    return PortStatus.CHECK_FAILED


def _run_docker_probe(port: int, *, timeout_s: float) -> subprocess.CompletedProcess[str]:
    """Spin up a short-lived helper container that exits immediately while holding the port.

    The container-side port (``1``) is arbitrary — only the host-side ``-p``
    binding matters for the probe, so the body (``true``) exits instantly
    without listening.

    `--entrypoint=true` overrides whatever ENTRYPOINT the helper image
    declares. Without it, an image with its own entrypoint (e.g. the
    installer image when WEBTREES_HELPER_IMAGE points at it) would
    treat ``true`` as a CLI arg, abort, and surface as PortStatus.CHECK_FAILED
    instead of FREE — silently disabling port-conflict detection.

    Docker's default `--pull=missing` applies — the helper image is
    pulled lazily on the first probe in a process. Direct
    `python -m webtrees_installer` invocations (no pre-pulled helper)
    therefore still work after a one-time pull; the launcher and CI
    paths pre-pull the helper so the call is a no-op.
    """
    return subprocess.run(
        [
            "docker", "run", "--rm",
            "--entrypoint=true",
            "-p", f"{port}:1",
            get_helper_image(),
        ],
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )
