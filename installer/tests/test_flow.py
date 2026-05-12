"""Tests for the standalone-flow orchestrator."""

from __future__ import annotations

import re
from datetime import datetime
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from webtrees_installer.flow import StandaloneArgs, run_standalone
from webtrees_installer.ports import PortStatus
from webtrees_installer.prereq import PrereqError
from webtrees_installer.versions import Catalog, PhpEntry


_TEST_CATALOG = Catalog(
    php_entries=(
        PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),
    ),
    nginx_tag="1.28-r1",
    installer_version="0.1.0",
)


@pytest.fixture(autouse=True)
def silence_prereq_and_docker(tmp_path_factory, monkeypatch) -> None:
    """Stub prereq check, load_catalog and the docker volume pre-seed so
    flow tests stay hermetic and never invoke real docker.

    WEBTREES_INSTALLER_MANIFEST_DIR is pointed at a real (empty) directory
    so ``_resolve_manifest_dir`` succeeds; ``load_catalog`` is mocked, so
    the empty directory is never actually read. Tests that need to
    exercise ``_resolve_manifest_dir`` itself unset the env var via their
    own monkeypatch.
    """
    fake_manifest = tmp_path_factory.mktemp("fake_manifest")
    monkeypatch.setenv("WEBTREES_INSTALLER_MANIFEST_DIR", str(fake_manifest))
    with patch("webtrees_installer.flow.check_prerequisites"), \
         patch("webtrees_installer.flow.load_catalog", return_value=_TEST_CATALOG), \
         patch("webtrees_installer.flow._write_admin_password_secret") as ws:
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
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / "compose.yaml").is_file()
    assert (tmp_path / ".env").is_file()

    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    assert "/php-full:" in compose["services"]["phpfpm"]["image"]


def test_run_standalone_reveals_admin_password(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path)
    out = StringIO()
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        run_standalone(args, stdin=StringIO(), stdout=out)

    body = out.getvalue()
    assert "admin" in body
    assert re.search(r"[0-9a-f]{24}", body), body


def test_run_standalone_writes_admin_password_to_secrets_init(tmp_path: Path) -> None:
    """Compose.yaml must reference /secrets/wt_admin_password."""
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    compose_text = (tmp_path / "compose.yaml").read_text()
    assert "/secrets/wt_admin_password" in compose_text
    assert "WT_ADMIN_PASSWORD_FILE" in compose_text


def test_run_standalone_aborts_on_existing_file_without_force(tmp_path: Path) -> None:
    (tmp_path / "compose.yaml").write_text("# existing")
    args = _args(work_dir=tmp_path, force=False)

    with pytest.raises(PrereqError):
        run_standalone(args, stdin=StringIO(), stdout=StringIO())


def test_run_standalone_port_in_use_falls_back_to_8080(tmp_path: Path) -> None:
    """Non-interactive flow: port 80 IN_USE → wizard bumps to 8080."""
    args = _args(work_dir=tmp_path, app_port=80)

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


def test_resolve_manifest_dir_raises_when_unset_and_default_missing(
    tmp_path: Path, monkeypatch
) -> None:
    """No env var + no /opt/installer/versions → PrereqError with actionable hint."""
    monkeypatch.delenv("WEBTREES_INSTALLER_MANIFEST_DIR", raising=False)
    monkeypatch.setattr(
        "webtrees_installer.flow._DEFAULT_MANIFEST_DIR",
        tmp_path / "definitely-missing",
    )
    from webtrees_installer.flow import _resolve_manifest_dir
    with pytest.raises(PrereqError, match="MANIFEST_DIR"):
        _resolve_manifest_dir()


def test_resolve_manifest_dir_honours_env_var(monkeypatch, tmp_path: Path) -> None:
    """An explicit WEBTREES_INSTALLER_MANIFEST_DIR wins over the in-image default."""
    monkeypatch.setenv("WEBTREES_INSTALLER_MANIFEST_DIR", str(tmp_path))
    from webtrees_installer.flow import _resolve_manifest_dir
    assert _resolve_manifest_dir() == tmp_path
