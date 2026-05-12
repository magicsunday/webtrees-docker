"""Live port-conflict probe via a short-lived Alpine container."""

from __future__ import annotations

import enum
import subprocess


# Public knob: callers can pass `timeout_s=PROBE_TIMEOUT_S * 2` or similar
# to scale the deadline relative to the default without hardcoding seconds.
PROBE_TIMEOUT_S = 20

# Private dependency pin: the image is an implementation detail of the probe.
_PROBE_IMAGE = "alpine:3.20"

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
    """Try to bind `port` on the host via a short-lived alpine container.

    Args:
        port: Host TCP port in the range ``1..65535``.
        timeout_s: Override for the subprocess deadline. ``None`` keeps the
            module default (``PROBE_TIMEOUT_S``); raise it for slow runners
            that may need to pull the alpine image on first invocation.

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
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return PortStatus.CHECK_FAILED

    if result.returncode == 0:
        return PortStatus.FREE
    stderr_lower = (result.stderr or "").lower()
    if any(phrase in stderr_lower for phrase in _IN_USE_PHRASES):
        return PortStatus.IN_USE
    return PortStatus.CHECK_FAILED


def _run_docker_probe(port: int, *, timeout_s: float) -> subprocess.CompletedProcess[str]:
    """Spin up an alpine container that exits immediately while holding the port.

    The container-side port (``1``) is arbitrary — only the host-side ``-p``
    binding matters for the probe, so the alpine command (``true``) exits
    instantly without listening.
    """
    return subprocess.run(
        [
            "docker", "run", "--rm",
            "-p", f"{port}:1",
            _PROBE_IMAGE,
            "true",
        ],
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )
