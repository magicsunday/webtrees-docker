"""Tests for stack.py — docker compose up + healthcheck wait."""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from webtrees_installer.stack import StackError, bring_up


def _completed(stdout: str = "", returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=""
    )


def test_bring_up_calls_compose_up(tmp_path: Path) -> None:
    """bring_up issues `docker compose up -d` in work_dir."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.side_effect = [
            _completed(),                       # up -d
            _completed(stdout="healthy\n"),     # inspect health
        ]
        bring_up(work_dir=tmp_path, timeout_s=10, poll_interval_s=0.01)

    first_call = compose.call_args_list[0]
    assert first_call.args[0] == ["compose", "up", "-d"]
    assert first_call.kwargs["cwd"] == tmp_path


def test_bring_up_waits_until_healthy(tmp_path: Path) -> None:
    """Polling sees 'starting' twice then 'healthy' — returns normally."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.side_effect = [
            _completed(),                        # up -d
            _completed(stdout="starting\n"),     # inspect 1
            _completed(stdout="starting\n"),     # inspect 2
            _completed(stdout="healthy\n"),      # inspect 3
        ]
        bring_up(work_dir=tmp_path, timeout_s=10, poll_interval_s=0.01)


def test_bring_up_times_out(tmp_path: Path) -> None:
    """All polls return 'starting' → StackError."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.return_value = _completed(stdout="starting\n")
        with pytest.raises(StackError, match="not become healthy"):
            bring_up(work_dir=tmp_path, timeout_s=0.05, poll_interval_s=0.01)


def test_bring_up_propagates_compose_failure(tmp_path: Path) -> None:
    """`docker compose up -d` failing → StackError with the stderr blob."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="image pull failed",
        )
        with pytest.raises(StackError, match="image pull failed"):
            bring_up(work_dir=tmp_path, timeout_s=10, poll_interval_s=0.01)
