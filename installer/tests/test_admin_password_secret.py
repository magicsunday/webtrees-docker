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
from unittest.mock import MagicMock, patch

import pytest
import subprocess

from webtrees_installer._alpine import ALPINE_BASE_IMAGE, HELPER_IMAGE_ENV_VAR
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

    # First call (volume create) succeeds; second (helper write) fails;
    # third (rm -f) must run for cleanup.
    cmds_received: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        cmds_received.append(cmd)
        if cmd[1] == "run":  # the helper-image write
            raise subprocess.CalledProcessError(
                returncode=1, cmd=cmd, stderr="helper: ENOSPC",
            )
        return _ok()

    with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
        with pytest.raises(PrereqError, match="helper: ENOSPC"):
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    # docker volume rm -f must have run after the failure.
    assert any(
        cmd[:4] == ["docker", "volume", "rm", "-f"] for cmd in cmds_received
    )


def test_pre_seed_timeout_cleans_volume_and_raises_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A wedged docker daemon during the helper write must surface as a
    PrereqError with a timeout-shaped message, and the half-created
    secrets volume must still get cleaned up via `docker volume rm -f`.
    Without the explicit timeout handler the wizard would hang
    indefinitely on a slow registry or stuck containerd snapshotter."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    cmds_received: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        cmds_received.append(cmd)
        if cmd[1] == "run":
            raise subprocess.TimeoutExpired(cmd=cmd, timeout=30.0)
        return _ok()

    with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
        with pytest.raises(PrereqError, match="timed out"):
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    assert any(
        cmd[:4] == ["docker", "volume", "rm", "-f"] for cmd in cmds_received
    )


def test_volume_create_failure_raises_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failing `docker volume create` must surface as a PrereqError,
    not as a raw subprocess traceback. No volume rollback is necessary
    because the create did not complete."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    def fake_run(cmd, **kwargs):
        if cmd[:3] == ["docker", "volume", "create"]:
            raise subprocess.CalledProcessError(
                returncode=1, cmd=cmd,
                stderr="permission denied while contacting daemon socket",
            )
        return _ok()

    with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
        with pytest.raises(PrereqError, match="failed to create secrets volume"):
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")


def test_volume_create_timeout_raises_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A wedged daemon during `docker volume create` must surface as a
    PrereqError with a timeout-shaped message rather than escaping as a
    raw `subprocess.TimeoutExpired` traceback."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    def fake_run(cmd, **kwargs):
        if cmd[:3] == ["docker", "volume", "create"]:
            raise subprocess.TimeoutExpired(cmd=cmd, timeout=30.0)
        return _ok()

    with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
        with pytest.raises(PrereqError, match="failed to create secrets volume.*timed out"):
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")


def test_rollback_timeout_does_not_mask_original_seed_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When a wedged daemon causes both the seed AND its rollback to
    time out, the operator must still see the original 'failed to
    pre-seed admin password' error rather than the cleanup
    `TimeoutExpired` masking it as a raw traceback."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    def fake_run(cmd, **kwargs):
        if cmd[1] == "run":
            raise subprocess.TimeoutExpired(cmd=cmd, timeout=30.0)
        if cmd[:4] == ["docker", "volume", "rm", "-f"]:
            raise subprocess.TimeoutExpired(cmd=cmd, timeout=30.0)
        return _ok()

    with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
        with pytest.raises(PrereqError, match="failed to pre-seed admin password.*timed out") as exc_info:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    # The chained cause must point at the SEED's TimeoutExpired, not the
    # rollback's — otherwise the operator's traceback walks them through
    # the cleanup path instead of the actual failure.
    assert isinstance(exc_info.value.__cause__, subprocess.TimeoutExpired)
    assert exc_info.value.__cause__.cmd[1] == "run"


def test_pre_seed_oserror_cleans_volume_and_raises_prereq_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A missing docker binary (PATH stripped, exec bit cleared) or
    socket EACCES manifests as an OSError out of subprocess.run. The
    seed except band must surface it as a PrereqError just like the
    other docker-wrapping helpers in the same module, instead of
    leaking a raw Python traceback past the CLI's exit-code-2 channel.

    The rollback `docker volume rm -f` also raises FileNotFoundError
    in this scenario (the binary is missing for that call too) — the
    inner except must swallow it so the operator sees the SEED's
    original error, not the cleanup-path failure that masks it."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")

    cmds_received: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        cmds_received.append(cmd)
        if cmd[1] == "run":
            raise FileNotFoundError(2, "No such file or directory", "docker")
        if cmd[:4] == ["docker", "volume", "rm", "-f"]:
            raise FileNotFoundError(2, "No such file or directory", "docker")
        return _ok()

    with patch("webtrees_installer.flow.subprocess.run", side_effect=fake_run):
        with pytest.raises(PrereqError, match="failed to pre-seed admin password") as exc_info:
            _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    # Even though the rollback also raised FileNotFoundError, the
    # PrereqError must chain back to the SEED's FileNotFoundError, not
    # the cleanup's.
    assert isinstance(exc_info.value.__cause__, FileNotFoundError)
    assert exc_info.value.__cause__.filename == "docker"
    # The rollback rm -f WAS attempted (recorded by fake_run before
    # raising), even though it then raised and was swallowed.
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


def _docker_run_argv(run_mock: MagicMock) -> list[str]:
    """Return the argv of the first `docker run …` call in a recorded mock.

    `_write_admin_password_secret` issues volume-management calls
    (`docker volume create` and on the failure path `docker volume rm`)
    alongside the seed itself; only the seed uses `docker run`.
    """
    for call in run_mock.call_args_list:
        argv = call.args[0]
        if argv[:2] == ["docker", "run"]:
            return argv
    raise AssertionError(f"no `docker run` call recorded; got {run_mock.call_args_list}")


def test_defaults_to_alpine_base_image_when_no_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Unset env var resolves the helper image to the canonical Alpine
    pin AND keeps `--entrypoint=sh` in place — the entrypoint override
    is unconditional, not gated on the env-var path."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    monkeypatch.delenv(HELPER_IMAGE_ENV_VAR, raising=False)

    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_ok(),
    ) as run:
        _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    argv = _docker_run_argv(run)
    assert ALPINE_BASE_IMAGE in argv
    assert "--entrypoint=sh" in argv


def test_helper_image_override_replaces_alpine_in_docker_run(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Override env var swaps the helper image in the docker-run argv."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    override = "ghcr.io/magicsunday/webtrees-installer:1.0.0"
    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, override)

    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_ok(),
    ) as run:
        _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    argv = _docker_run_argv(run)
    assert override in argv
    # Any leftover alpine reference alongside an override would silently
    # re-introduce the very Docker Hub pull the override is meant to skip.
    assert ALPINE_BASE_IMAGE not in argv


def test_admin_seed_forces_sh_entrypoint(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`--entrypoint=sh` must accompany the helper image regardless of
    which image WEBTREES_HELPER_IMAGE points at — without it, an image
    that declares its own ENTRYPOINT (e.g. the installer image itself
    runs `python -m webtrees_installer`) would treat the trailing
    `-ec '…'` as CLI args, abort, and leave the secret unwritten."""
    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "myproj")
    override = "ghcr.io/magicsunday/webtrees-installer:1.0.0"
    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, override)

    with patch(
        "webtrees_installer.flow.subprocess.run",
        return_value=_ok(),
    ) as run:
        _write_admin_password_secret(work_dir=Path("/tmp/x"), password="pw")

    argv = _docker_run_argv(run)
    assert "--entrypoint=sh" in argv

    # The seed script must arrive as the CMD args (-ec '<body>') AFTER the
    # image positional — otherwise `sh` reads nothing on stdin and the
    # umask/chmod sequence never executes.
    image_index = argv.index(override)
    cmd_after_image = argv[image_index + 1 : image_index + 3]
    assert cmd_after_image[0] == "-ec"
    assert "wt_admin_password" in cmd_after_image[1]
