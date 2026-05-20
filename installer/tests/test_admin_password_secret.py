"""Unit tests for `_write_admin_password_secret` and `_installer_image`.

Separate file: the orchestrator-level autouse fixture in
``test_flow.py`` stubs this helper out entirely, so the function's
own code path never executes under that suite. The tests here mock
the external collaborators (``subprocess.run``, ``_installer_image``)
but execute the real helper, locking down:

* the project-derived volume name,
* the password reaches the seed container via stdin (never argv, never
  a temp file),
* when the installer image is detected, it is used with ``--pull=never``
  (no Docker Hub pull needed — the image is already on the host),
* when the installer image cannot be detected, Alpine is used as
  fallback with ``--pull=missing``,
* a failing pre-seed cleans up the half-created volume and re-raises
  as `PrereqError`,
* the no-`COMPOSE_PROJECT_NAME` path still surfaces the
  helpful guidance from `_compose_project_name` instead of a
  generic Docker error.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
import subprocess

from webtrees_installer._alpine import ALPINE_BASE_IMAGE
from webtrees_installer.flow import _installer_image, _write_admin_password_secret
from webtrees_installer.prereq import PrereqError


def _ok(stdout: str = "", stderr: str = "") -> SimpleNamespace:
    return SimpleNamespace(stdout=stdout, returncode=0, stderr=stderr)


# ---------------------------------------------------------------------------
# _write_admin_password_secret — alpine fallback path
# (installer image not detectable, e.g. local Python invocation)
# ---------------------------------------------------------------------------


def test_calls_docker_volume_create_with_project_scoped_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    with patch("webtrees_installer.flow._installer_image", return_value=None):
        with patch(
            "webtrees_installer.flow.subprocess.run",
            return_value=_ok(),
        ) as run:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="hunter2")

    # First call must be docker volume create against `<project>_secrets`.
    first = run.call_args_list[0].args[0]
    assert first == ["docker", "volume", "create", "myproj_secrets"]


def test_pipes_password_via_stdin_not_argv(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    password = "supersecret-ABC123"
    with patch("webtrees_installer.flow._installer_image", return_value=None):
        with patch(
            "webtrees_installer.flow.subprocess.run",
            return_value=_ok(),
        ) as run:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password=password)

    # Second call writes the secret; argv must not contain the password
    # (would leak via `ps` / docker logs), and the input= kwarg carries
    # it via stdin instead.
    second = run.call_args_list[1]
    assert password not in " ".join(second.args[0])
    assert second.kwargs["input"] == password


def test_alpine_fallback_uses_pull_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When installer image is not detectable, Alpine is used with --pull=missing."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    with patch("webtrees_installer.flow._installer_image", return_value=None):
        with patch(
            "webtrees_installer.flow.subprocess.run",
            return_value=_ok(),
        ) as run:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    docker_run_cmd = run.call_args_list[1].args[0]
    assert "--pull=missing" in docker_run_cmd
    assert ALPINE_BASE_IMAGE in docker_run_cmd


def test_pre_seed_failure_cleans_volume_and_raises_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    # First call (volume create) succeeds; second (seed write) fails;
    # third (rm -f) must run for cleanup.
    cmds_received: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        cmds_received.append(cmd)
        if cmd[1] == "run":  # the seed write
            raise subprocess.CalledProcessError(
                returncode=1, cmd=cmd, stderr="alpine: ENOSPC",
            )
        return _ok()

    with patch("webtrees_installer.flow._installer_image", return_value=None):
        with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
            with pytest.raises(PrereqError, match="alpine: ENOSPC"):
                _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    # docker volume rm -f must have run after the failure.
    assert any(
        cmd[:4] == ["docker", "volume", "rm", "-f"] for cmd in cmds_received
    )


def test_propagates_project_name_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Unlike `_list_surviving_volumes` (which degrades silently), the
    # admin-password helper genuinely needs the project name — its whole
    # purpose is to pre-seed the project-scoped secrets volume. If the
    # name cannot be derived, fail loudly so the caller never thinks the
    # password landed safely.
    monkeypatch.delenv("COMPOSE_PROJECT_NAME", raising=False)

    with pytest.raises(PrereqError, match="COMPOSE_PROJECT_NAME"):
        _write_admin_password_secret(work_dir=Path("/work"), password="pw")


# ---------------------------------------------------------------------------
# _write_admin_password_secret — installer-image path
# (running inside Docker; image already on host, no Docker Hub pull)
# ---------------------------------------------------------------------------

_INSTALLER_IMAGE = "ghcr.io/magicsunday/webtrees-installer:1.0.0"


def test_uses_installer_image_with_pull_never_when_detected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When inside Docker, the installer's own image is used with --pull=never."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    with patch(
        "webtrees_installer.flow._installer_image",
        return_value=_INSTALLER_IMAGE,
    ):
        with patch(
            "webtrees_installer.flow.subprocess.run",
            return_value=_ok(),
        ) as run:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    docker_run_cmd = run.call_args_list[1].args[0]
    assert "--pull=never" in docker_run_cmd
    assert _INSTALLER_IMAGE in docker_run_cmd
    assert ALPINE_BASE_IMAGE not in docker_run_cmd


def test_installer_image_password_still_via_stdin(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Password must reach the seed container via stdin regardless of image."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    password = "secret-XYZ789"
    with patch(
        "webtrees_installer.flow._installer_image",
        return_value=_INSTALLER_IMAGE,
    ):
        with patch(
            "webtrees_installer.flow.subprocess.run",
            return_value=_ok(),
        ) as run:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password=password)

    second = run.call_args_list[1]
    assert password not in " ".join(second.args[0])
    assert second.kwargs["input"] == password


# ---------------------------------------------------------------------------
# _installer_image — unit tests
# ---------------------------------------------------------------------------


def test_installer_image_returns_image_when_inspect_succeeds(
    tmp_path: Path,
) -> None:
    """Returns the image name reported by docker inspect."""
    hostname_file = tmp_path / "hostname"
    hostname_file.write_text("abc123def456\n")

    with patch("webtrees_installer.flow.Path") as mock_path_cls:
        mock_path_cls.side_effect = lambda p: (
            hostname_file if p == "/proc/self/hostname" else Path(p)
        )
        with patch(
            "webtrees_installer.flow.subprocess.run",
            return_value=_ok(stdout="ghcr.io/magicsunday/webtrees-installer:1.0.0\n"),
        ):
            result = _installer_image()

    assert result == "ghcr.io/magicsunday/webtrees-installer:1.0.0"


def test_installer_image_returns_none_when_inspect_fails() -> None:
    """Returns None when docker inspect fails (not running in Docker)."""
    with patch(
        "webtrees_installer.flow.subprocess.run",
        side_effect=subprocess.CalledProcessError(1, "docker inspect"),
    ):
        with patch(
            "webtrees_installer.flow.Path",
            side_effect=lambda p: Path(p),
        ):
            result = _installer_image()

    assert result is None


def test_installer_image_returns_none_when_hostname_file_missing() -> None:
    """Returns None when /proc/self/hostname cannot be read."""
    with patch("webtrees_installer.flow.Path") as mock_path_cls:
        mock_path_cls.return_value.read_text.side_effect = OSError("no file")
        mock_path_cls.side_effect = lambda p: mock_path_cls.return_value
        result = _installer_image()

    assert result is None


def test_installer_image_returns_none_when_inspect_returns_empty() -> None:
    """Returns None when docker inspect produces an empty image string."""
    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_ok(stdout=""),
    ):
        with patch(
            "webtrees_installer.flow.Path",
            side_effect=lambda p: Path(p),
        ):
            result = _installer_image()

    assert result is None

