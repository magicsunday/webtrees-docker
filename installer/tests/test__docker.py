"""Tests for the shared run_docker wrapper.

run_docker is the single seam every docker shell-out in the package
routes through (flow.py's volume + seed calls, dev_flow's compose
calls). These tests pin the invocation contract those call sites depend
on — a dropped `input=` would silently break the admin-password seed, a
dropped `check=` would turn a hard failure into a swallowed one.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from webtrees_installer._docker import run_docker


def test_run_docker_prepends_docker_and_pins_capture_text() -> None:
    """The binary is always `docker`, always in captured text mode, and
    the optional knobs default to no-cwd / no-raise / no-timeout / no-stdin."""
    with patch("webtrees_installer._docker.subprocess.run") as mock_run:
        run_docker(["volume", "ls"])

    args, kwargs = mock_run.call_args
    assert args[0] == ["docker", "volume", "ls"]
    assert kwargs["capture_output"] is True
    assert kwargs["text"] is True
    assert kwargs["cwd"] is None
    assert kwargs["check"] is False
    assert kwargs["timeout"] is None
    assert kwargs["input"] is None


def test_run_docker_forwards_optional_kwargs() -> None:
    """cwd / check / timeout / input each reach subprocess.run unchanged."""
    with patch("webtrees_installer._docker.subprocess.run") as mock_run:
        run_docker(
            ["run", "--rm", "-i", "img"],
            cwd=Path("/work"),
            check=True,
            timeout=30.0,
            input="secret",
        )

    args, kwargs = mock_run.call_args
    assert args[0] == ["docker", "run", "--rm", "-i", "img"]
    assert kwargs["cwd"] == Path("/work")
    assert kwargs["check"] is True
    assert kwargs["timeout"] == 30.0
    assert kwargs["input"] == "secret"
