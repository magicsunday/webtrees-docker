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
        assert probe_port(8080) is PortStatus.FREE


@pytest.mark.parametrize(
    "stderr",
    [
        "bind: address already in use",
        "Bind for 0.0.0.0:8080 failed: port is already allocated",
        "Ports are not available: exposing port TCP 0.0.0.0:8080 → 0.0.0.0:1",
    ],
)
def test_probe_port_in_use_recognises_known_phrasings(stderr: str) -> None:
    """All three known docker-daemon variants of 'port taken' → IN_USE."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=125, stdout="", stderr=stderr,
        )
        assert probe_port(8080) is PortStatus.IN_USE


def test_probe_port_check_failed_on_unrelated_error() -> None:
    """Unexpected docker error → CHECK_FAILED (caller downgrades to warn)."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="docker: permission denied",
        )
        assert probe_port(8080) is PortStatus.CHECK_FAILED


def test_probe_port_check_failed_on_subprocess_error() -> None:
    """docker CLI itself missing / hangs → CHECK_FAILED."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.side_effect = FileNotFoundError("docker not on PATH")
        assert probe_port(8080) is PortStatus.CHECK_FAILED


def test_probe_port_honours_custom_timeout() -> None:
    """Caller-supplied timeout_s overrides the module default."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="", stderr="",
        )
        probe_port(8080, timeout_s=120.0)
        assert run.call_args.kwargs["timeout_s"] == 120.0


def test_probe_port_honours_zero_timeout() -> None:
    """`timeout_s=0` must not silently fall back to the default."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="", stderr="",
        )
        probe_port(8080, timeout_s=0)
        assert run.call_args.kwargs["timeout_s"] == 0


@pytest.mark.parametrize("invalid", [0, -1, 65536, 99999])
def test_probe_port_rejects_invalid_port(invalid: int) -> None:
    """Out-of-range ports raise ValueError before invoking docker."""
    with pytest.raises(ValueError, match="port"):
        probe_port(invalid)
