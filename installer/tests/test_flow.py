"""Tests for the standalone-flow orchestrator."""

from __future__ import annotations

from io import StringIO
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from webtrees_installer.flow import StandaloneArgs, run_standalone


@pytest.fixture(autouse=True)
def silence_prereq_and_docker() -> None:
    """Flow tests stub the prereq check and the docker volume pre-seed."""
    with patch("webtrees_installer.flow.check_prerequisites"), \
         patch("webtrees_installer.flow._write_admin_password_secret") as ws:
        # Forward to a lightweight version that only drops the /work file,
        # skipping the docker volume create + ephemeral container.
        def fake(*, work_dir: Path, password: str) -> None:
            (work_dir / ".webtrees-admin-password").write_text(password + "\n")
        ws.side_effect = fake
        yield


def _args(**overrides) -> StandaloneArgs:
    """Build a StandaloneArgs with non-interactive defaults that exercise the happy path."""
    defaults = dict(
        work_dir=None,
        interactive=False,
        edition="full",
        proxy_mode="standalone",
        app_port=8080,
        domain=None,
        admin_bootstrap=True,
        admin_user="admin",
        admin_email="admin@example.org",
        force=True,
        no_up=True,
    )
    defaults.update(overrides)
    return StandaloneArgs(**defaults)


def test_run_standalone_writes_compose_and_env(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.flow.probe_port") as probe:
        probe.return_value = __import__(
            "webtrees_installer.ports", fromlist=["PortStatus"]
        ).PortStatus.FREE
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / "compose.yaml").is_file()
    assert (tmp_path / ".env").is_file()

    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    assert "/php-full:" in compose["services"]["phpfpm"]["image"]


def test_run_standalone_reveals_admin_password(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path)
    out = StringIO()
    with patch("webtrees_installer.flow.probe_port") as probe:
        probe.return_value = __import__(
            "webtrees_installer.ports", fromlist=["PortStatus"]
        ).PortStatus.FREE
        run_standalone(args, stdin=StringIO(), stdout=out)

    body = out.getvalue()
    assert "admin" in body
    import re
    assert re.search(r"[0-9a-f]{24}", body), body


def test_run_standalone_writes_admin_password_to_secrets_init(tmp_path: Path) -> None:
    """Compose.yaml must reference /secrets/wt_admin_password."""
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.flow.probe_port") as probe:
        probe.return_value = __import__(
            "webtrees_installer.ports", fromlist=["PortStatus"]
        ).PortStatus.FREE
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    compose_text = (tmp_path / "compose.yaml").read_text()
    assert "/secrets/wt_admin_password" in compose_text
    assert "WT_ADMIN_PASSWORD_FILE" in compose_text


def test_run_standalone_aborts_on_existing_file_without_force(tmp_path: Path) -> None:
    (tmp_path / "compose.yaml").write_text("# existing")
    args = _args(work_dir=tmp_path, force=False)

    from webtrees_installer.prereq import PrereqError
    with pytest.raises(PrereqError):
        run_standalone(args, stdin=StringIO(), stdout=StringIO())


def test_run_standalone_port_in_use_falls_back_to_8080(tmp_path: Path) -> None:
    """Non-interactive flow: port 80 IN_USE → wizard bumps to 8080."""
    args = _args(work_dir=tmp_path, app_port=80)
    from webtrees_installer.ports import PortStatus

    side_effects = iter([PortStatus.IN_USE, PortStatus.FREE])
    with patch("webtrees_installer.flow.probe_port", side_effect=lambda p: next(side_effects)):
        out = StringIO()
        exit_code = run_standalone(args, stdin=StringIO(), stdout=out)

    assert exit_code == 0
    compose_text = (tmp_path / "compose.yaml").read_text()
    # The standalone template renders ports as ${APP_PORT:-<chosen>}:80, so
    # the fallback bump shows up both as the .env override and as the inline
    # default. Match against the rendered substring rather than `8080:80`.
    assert "${APP_PORT:-8080}:80" in compose_text
    assert "APP_PORT=8080" in (tmp_path / ".env").read_text()
