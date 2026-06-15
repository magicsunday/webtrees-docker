"""Tests for the runtime prerequisite checks."""

from __future__ import annotations

import subprocess
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import pytest

from webtrees_installer.prereq import (
    COMPOSE_VERSION_TIMEOUT_S,
    PrereqError,
    check_prerequisites,
    check_traefik_network,
    confirm_overwrite,
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


def test_check_prerequisites_compose_v3_plus(tmp_path: Path) -> None:
    """A Compose major newer than v2 (e.g. v5.1.4) is still the plugin → accepted."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="Docker Compose version v5.1.4",
    ):
        check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_compose_no_v_prefix(tmp_path: Path) -> None:
    """Some distro packages omit the leading 'v' (e.g. 'version 2.29.7') → accepted."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="Docker Compose version 2.29.7",
    ):
        check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_compose_unknown_format(tmp_path: Path) -> None:
    """An unparseable banner (no `vN.` major) is rejected like a stranger format."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="some unexpected output",
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


def test_confirm_overwrite_no_conflict(tmp_path: Path) -> None:
    """Clean /work → no prompt, returns True."""
    assert confirm_overwrite(work_dir=tmp_path, interactive=True) is True


def test_confirm_overwrite_prompts_when_compose_exists(tmp_path: Path) -> None:
    """compose.yaml present + user replies 'n' → returns False."""
    (tmp_path / "compose.yaml").write_text("# existing")
    answer = confirm_overwrite(
        work_dir=tmp_path,
        interactive=True,
        stdin=StringIO("n\n"),
        stdout=StringIO(),
    )
    assert answer is False


def test_confirm_overwrite_prompts_when_compose_exists_yes(tmp_path: Path) -> None:
    """compose.yaml present + user replies 'y' → returns True."""
    (tmp_path / "compose.yaml").write_text("# existing")
    answer = confirm_overwrite(
        work_dir=tmp_path,
        interactive=True,
        stdin=StringIO("y\n"),
        stdout=StringIO(),
    )
    assert answer is True


def test_confirm_overwrite_names_scopes_conflict_to_written_files(tmp_path: Path) -> None:
    """The dev flow writes only .env, so a present compose.yaml it does NOT
    write must not count as a conflict (names=('.env',)). Otherwise the
    always-present repo compose.yaml would falsely block a first dev
    install. With no .env yet, the guard proceeds even non-interactively
    without --force."""
    (tmp_path / "compose.yaml").write_text("# repo compose, not written by dev flow")
    assert confirm_overwrite(
        work_dir=tmp_path, interactive=False, force=False, names=(".env",)
    ) is True


def test_confirm_overwrite_names_still_flags_a_written_file(tmp_path: Path) -> None:
    """An existing .env DOES conflict when .env is in the written set."""
    (tmp_path / ".env").write_text("X=1")
    with pytest.raises(PrereqError, match=r"--force"):
        confirm_overwrite(
            work_dir=tmp_path, interactive=False, force=False, names=(".env",)
        )


def test_confirm_overwrite_noninteractive_without_force(tmp_path: Path) -> None:
    """Non-interactive + conflict + no force flag → PrereqError."""
    (tmp_path / "compose.yaml").write_text("# existing")
    with pytest.raises(PrereqError, match=r"--force"):
        confirm_overwrite(work_dir=tmp_path, interactive=False, force=False)


def test_confirm_overwrite_noninteractive_with_force(tmp_path: Path) -> None:
    """Non-interactive + force=True → returns True regardless of files."""
    (tmp_path / "compose.yaml").write_text("# existing")
    (tmp_path / ".env").write_text("X=1")
    assert confirm_overwrite(work_dir=tmp_path, interactive=False, force=True) is True


def test_confirm_overwrite_interactive_eof_preserves_files(tmp_path: Path) -> None:
    """Closed/EOF stdin yields the empty reply, which must default to No."""
    (tmp_path / "compose.yaml").write_text("# existing")
    answer = confirm_overwrite(
        work_dir=tmp_path,
        interactive=True,
        stdin=StringIO(""),
        stdout=StringIO(),
    )
    assert answer is False


def test_check_traefik_network_raises_when_network_missing() -> None:
    """`docker network inspect <missing>` exits non-zero — the prereq
    helper must surface that as a PrereqError so `compose up` is never
    attempted for a network that doesn't exist (issue #131). The error
    text must include the missing network name and the operator-facing
    `docker network create` remediation hint."""
    with patch("webtrees_installer.prereq.subprocess.run") as mock_run:
        mock_run.side_effect = subprocess.CalledProcessError(
            returncode=1,
            cmd=["docker", "network", "inspect", "missing-net"],
            stderr="Error: No such network: missing-net\n",
        )
        with pytest.raises(PrereqError, match="missing-net"):
            check_traefik_network(network="missing-net")
