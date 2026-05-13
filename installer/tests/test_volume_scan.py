"""Unit tests for `_list_surviving_volumes`.

Separate file on purpose: ``test_flow.py``'s autouse fixture stubs
``_list_surviving_volumes`` itself so the flow-orchestration tests
stay hermetic. That stub structurally hides every failure mode of
the helper's *own* implementation — exactly the gap that let a
``PrereqError`` escape from ``--no-admin --no-up`` smoke cells
unnoticed. The tests in this file mock the helper's *external
collaborators* (subprocess + env) but execute the real helper
body, so a future regression in the project-name handling or the
``docker volume ls`` invocation fails locally instead of on a CI
runner at 09:00.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from webtrees_installer.flow import _list_surviving_volumes


def _fake_docker_ls(stdout: str = "") -> SimpleNamespace:
    """Build the subprocess.run return value for a `docker volume ls`."""
    return SimpleNamespace(stdout=stdout, returncode=0, stderr="")


def test_silent_when_project_name_underivable_at_work_mount(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Reproduces the failure mode that red-lit smoke demo cells: cwd
    # `/work` inside the installer container without COMPOSE_PROJECT_NAME
    # raises PrereqError from _compose_project_name. The helper must
    # treat that as "nothing to scan" rather than crashing the whole
    # install — `--no-admin --no-up` flows do not pre-seed a secrets
    # volume so the project-name constraint genuinely does not apply.
    monkeypatch.delenv("COMPOSE_PROJECT_NAME", raising=False)
    assert _list_surviving_volumes(Path("/work")) == []


def test_returns_empty_on_clean_daemon(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "testproj")
    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_fake_docker_ls(stdout=""),
    ):
        assert _list_surviving_volumes(Path("/tmp/anywhere")) == []


def test_parses_docker_volume_ls_output(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "testproj")
    output = "testproj_app\ntestproj_database\ntestproj_secrets\n"
    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_fake_docker_ls(stdout=output),
    ) as run:
        result = _list_surviving_volumes(Path("/tmp/anywhere"))

    assert result == ["testproj_app", "testproj_database", "testproj_secrets"]
    # Confirm the filter scopes to our project (anchored regex), so a
    # sibling project's volumes never accidentally match.
    args = run.call_args.args[0]
    assert "--filter" in args
    assert "name=^testproj_" in args


def test_strips_blank_lines(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "testproj")
    # docker volume ls can emit a trailing newline that splitlines()
    # turns into a blank entry; assert it never leaks into the result.
    output = "testproj_app\n\ntestproj_database\n"
    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_fake_docker_ls(stdout=output),
    ):
        result = _list_surviving_volumes(Path("/tmp/anywhere"))

    assert result == ["testproj_app", "testproj_database"]
