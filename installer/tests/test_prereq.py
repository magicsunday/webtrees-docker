"""Tests for the runtime prerequisite checks."""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from webtrees_installer.prereq import (
    COMPOSE_VERSION_TIMEOUT_S,
    PrereqError,
    check_prerequisites,
)


def test_check_prerequisites_ok(tmp_path: Path) -> None:
    """All probes pass → no exception, no return value."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="Docker Compose version v2.29.7",
    ):
        check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_missing_work(tmp_path: Path) -> None:
    """Missing /work raises with a `docker run -v` hint."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with pytest.raises(PrereqError, match=r"-v.*:/work"):
        check_prerequisites(
            work_dir=tmp_path / "does-not-exist",
            docker_sock=sock,
        )


def test_check_prerequisites_missing_socket(tmp_path: Path) -> None:
    """Missing /var/run/docker.sock raises with the bind-mount hint."""
    with pytest.raises(PrereqError, match=r"/var/run/docker.sock"):
        check_prerequisites(
            work_dir=tmp_path,
            docker_sock=tmp_path / "absent.sock",
        )


def test_check_prerequisites_compose_v1(tmp_path: Path) -> None:
    """Compose v1 reports `docker-compose version 1.x` → wizard rejects it."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="docker-compose version 1.29.2",
    ):
        with pytest.raises(PrereqError, match="Compose v2"):
            check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_docker_daemon_down(tmp_path: Path) -> None:
    """docker compose version errors → daemon-not-reachable hint."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        side_effect=subprocess.CalledProcessError(1, ["docker"], stderr="Cannot connect"),
    ):
        with pytest.raises(PrereqError, match="daemon"):
            check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_docker_daemon_hung(tmp_path: Path) -> None:
    """docker compose version hangs past the timeout → timeout hint."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        side_effect=subprocess.TimeoutExpired(
            cmd=["docker"], timeout=COMPOSE_VERSION_TIMEOUT_S,
        ),
    ):
        with pytest.raises(PrereqError, match="did not respond"):
            check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_called_process_error_with_no_stderr(tmp_path: Path) -> None:
    """CalledProcessError with stderr=None must not surface 'stderr: None'."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        side_effect=subprocess.CalledProcessError(1, ["docker"], stderr=None),
    ):
        with pytest.raises(PrereqError, match="<no stderr>"):
            check_prerequisites(work_dir=tmp_path, docker_sock=sock)
