"""Unit tests for `_write_admin_password_secret`.

Separate file: the orchestrator-level autouse fixture in
``test_flow.py`` stubs this helper out entirely, so the function's
own code path never executes under that suite. The tests here mock
the external collaborator (``subprocess.run``) but execute the real
helper, locking down:

* the project-derived volume name,
* the password reaches alpine via stdin (never argv, never a temp file),
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

from webtrees_installer.flow import _write_admin_password_secret
from webtrees_installer.prereq import PrereqError


def _ok(stdout: str = "", stderr: str = "") -> SimpleNamespace:
    return SimpleNamespace(stdout=stdout, returncode=0, stderr=stderr)


def test_calls_docker_volume_create_with_project_scoped_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
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
    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_ok(),
    ) as run:
        _write_admin_password_secret(work_dir=Path("/tmp/x"), password=password)

    # Second call writes the secret via alpine; argv must not contain the
    # password (would leak via `ps` / docker logs), and the input= kwarg
    # carries it via stdin instead.
    second = run.call_args_list[1]
    assert password not in " ".join(second.args[0])
    assert second.kwargs["input"] == password


def test_pre_seed_failure_cleans_volume_and_raises_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    # First call (volume create) succeeds; second (alpine write) fails;
    # third (rm -f) must run for cleanup.
    cmds_received: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        cmds_received.append(cmd)
        if cmd[1] == "run":  # the alpine write
            raise subprocess.CalledProcessError(
                returncode=1, cmd=cmd, stderr="alpine: ENOSPC",
            )
        return _ok()

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
