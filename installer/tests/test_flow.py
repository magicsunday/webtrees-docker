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
        demo=False,
        demo_seed=42,
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


def test_run_standalone_port_8080_in_use_short_circuits_without_redundant_probe(
    tmp_path: Path,
) -> None:
    """--port 8080 on a busy host raises immediately, skipping the redundant 8080 fallback probe."""
    args = _args(work_dir=tmp_path, app_port=8080)

    with patch(
        "webtrees_installer.flow.probe_port",
        return_value=PortStatus.IN_USE,
    ) as probe_mock:
        out = StringIO()
        with pytest.raises(PrereqError, match=r"port 8080 is in use; pass --port"):
            run_standalone(args, stdin=StringIO(), stdout=out)

    assert probe_mock.call_count == 1
    assert probe_mock.call_args.args == (8080,)
    assert "trying 8080 instead" not in out.getvalue()


def test_resolve_manifest_dir_raises_when_unset_and_default_missing(
    tmp_path: Path, monkeypatch
) -> None:
    """No env var + no in-image bake location → PrereqError with actionable hint."""
    monkeypatch.delenv("WEBTREES_INSTALLER_MANIFEST_DIR", raising=False)
    # Patch the canonical source of truth in versions.py; the flow.py
    # alias is a re-export, not a separate value, so patching it would
    # be a no-op.
    monkeypatch.setattr(
        "webtrees_installer.versions.DEFAULT_MANIFEST_DIR",
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


def test_run_standalone_invokes_bring_up_when_not_no_up(tmp_path: Path) -> None:
    """no_up=False → flow calls stack.bring_up."""
    args = _args(work_dir=tmp_path, no_up=False)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE), \
         patch("webtrees_installer.flow.bring_up") as bring_up_mock:
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    bring_up_mock.assert_called_once()
    assert bring_up_mock.call_args.kwargs["work_dir"] == tmp_path


def test_run_standalone_propagates_stack_error(tmp_path: Path) -> None:
    """bring_up raising StackError bubbles out of run_standalone unmodified.

    The CLI layer is what catches StackError and converts it to exit 3 +
    stderr; the flow itself must not swallow the error and return 3, since
    that would force every caller (including future Phase 2b dev-flow) to
    re-implement the stderr routing.
    """
    from webtrees_installer.stack import StackError
    args = _args(work_dir=tmp_path, no_up=False)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE), \
         patch("webtrees_installer.flow.bring_up", side_effect=StackError("boom")):
        with pytest.raises(StackError, match="boom"):
            run_standalone(args, stdin=StringIO(), stdout=StringIO())


def test_run_standalone_writes_demo_gedcom_when_demo_set(tmp_path: Path) -> None:
    """--demo true -> demo.ged is written next to compose.yaml."""
    args = _args(work_dir=tmp_path, demo=True, demo_seed=42)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    gedcom = tmp_path / "demo.ged"
    assert gedcom.is_file()
    content = gedcom.read_text()
    assert content.startswith("0 HEAD")
    assert "2 VERS 5.5.1" in content


def test_run_standalone_skips_demo_when_demo_unset(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path, demo=False, demo_seed=42)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert not (tmp_path / "demo.ged").exists()


def test_run_standalone_imports_demo_when_not_no_up(tmp_path: Path) -> None:
    """no_up=False + --demo -> wizard calls _import_demo_tree."""
    args = _args(work_dir=tmp_path, demo=True, demo_seed=42, no_up=False)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE), \
         patch("webtrees_installer.flow.bring_up"), \
         patch("webtrees_installer.flow._import_demo_tree") as import_mock:
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    import_mock.assert_called_once()


def test_compose_project_name_lowercases_and_strips(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Normalisation matches docker compose v2's project-name rules."""
    from webtrees_installer.flow import _compose_project_name

    monkeypatch.delenv("COMPOSE_PROJECT_NAME", raising=False)

    # Canonical install path stays unchanged.
    canonical = tmp_path / "webtrees"
    canonical.mkdir()
    assert _compose_project_name(canonical) == "webtrees"

    # Mixed case + dots collapse to a compose-legal bucket.
    weird = tmp_path / "My.Webtrees"
    weird.mkdir()
    assert _compose_project_name(weird) == "mywebtrees"

    # Underscores and hyphens survive the strip pass.
    mixed = tmp_path / "Foo-Bar_baz"
    mixed.mkdir()
    assert _compose_project_name(mixed) == "foo-bar_baz"


def test_compose_project_name_honours_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """COMPOSE_PROJECT_NAME env wins over cwd basename and still normalises."""
    from webtrees_installer.flow import _compose_project_name

    monkeypatch.setenv("COMPOSE_PROJECT_NAME", "Some.Custom-Name")
    assert _compose_project_name(tmp_path) == "somecustom-name"
