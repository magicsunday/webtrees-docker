"""Live port-conflict probe via a short-lived Alpine container."""

from __future__ import annotations

import enum
import subprocess


class PortStatus(enum.Enum):
    """Result of a probe_port() call."""

    FREE = "free"
    IN_USE = "in_use"
    CHECK_FAILED = "check_failed"


def probe_port(port: int) -> PortStatus:
    """Try to bind `port` on the host. Return whether it's free, taken or unprobeable."""
    if not 1 <= port <= 65535:
        raise ValueError(f"port out of range: {port}")

    try:
        result = _run_docker_probe(port)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return PortStatus.CHECK_FAILED

    if result.returncode == 0:
        return PortStatus.FREE
    if "address already in use" in (result.stderr or "").lower():
        return PortStatus.IN_USE
    return PortStatus.CHECK_FAILED


def _run_docker_probe(port: int) -> subprocess.CompletedProcess[str]:
    """Spin up an alpine container that exits immediately while holding the port."""
    return subprocess.run(
        [
            "docker", "run", "--rm",
            "-p", f"{port}:1",
            "alpine:3.20",
            "true",
        ],
        capture_output=True,
        text=True,
        timeout=20,
    )
