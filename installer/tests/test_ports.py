"""Tests for live port-conflict detection."""

from __future__ import annotations

import subprocess
from unittest.mock import patch

import pytest

from webtrees_installer.ports import PortStatus, probe_port


def test_probe_port_free() -> None:
    """docker run exits 0 → PortStatus.FREE."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        assert probe_port(8080) == PortStatus.FREE


def test_probe_port_in_use() -> None:
    """docker run exits non-zero with 'address already in use' → IN_USE."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=125,
            stdout="",
            stderr="bind: address already in use",
        )
        assert probe_port(8080) == PortStatus.IN_USE


def test_probe_port_check_failed_on_unrelated_error() -> None:
    """Unexpected docker error → CHECK_FAILED (caller downgrades to warn)."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="docker: permission denied",
        )
        assert probe_port(8080) == PortStatus.CHECK_FAILED


def test_probe_port_check_failed_on_subprocess_error() -> None:
    """docker CLI itself missing / hangs → CHECK_FAILED."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.side_effect = FileNotFoundError("docker not on PATH")
        assert probe_port(8080) == PortStatus.CHECK_FAILED


@pytest.mark.parametrize("invalid", [0, -1, 65536, 99999])
def test_probe_port_rejects_invalid_port(invalid: int) -> None:
    """Out-of-range ports raise ValueError before invoking docker."""
    with pytest.raises(ValueError, match="port"):
        probe_port(invalid)
