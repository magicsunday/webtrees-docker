"""Tests for the dev-flow renderer."""

from __future__ import annotations

from datetime import datetime
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import pytest

from webtrees_installer.dev_flow import (
    DevArgs,
    HostInfo,
    build_compose_chain,
    collect_dev_inputs,
    render_dev_env,
)
from webtrees_installer.versions import Catalog, PhpEntry


_HOST = HostInfo(uid=1000, username="dev", primary_ip="192.168.1.50")


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),),
        nginx_tag="1.28-r1",
        installer_version="0.1.0",
    )


def _args(**overrides) -> DevArgs:
    defaults = dict(
        work_dir=None,
        interactive=False,
        proxy_mode="standalone",
        dev_domain="webtrees.localhost:50010",
        app_port=50010,
        pma_port=50011,
        mariadb_host="db",
        mariadb_database="webtrees",
        mariadb_user="webtrees",
        mariadb_password="devpw",
        mariadb_root_password="rootpw",
        use_existing_db=False,
        use_external_db=False,
        local_user_id=1000,
        local_user_name="dev",
        force=True,
    )
    defaults.update(overrides)
    return DevArgs(**defaults)


def test_build_compose_chain_standalone() -> None:
    assert (
        build_compose_chain(proxy_mode="standalone", use_external_db=False)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml"
    )


def test_build_compose_chain_traefik() -> None:
    assert (
        build_compose_chain(proxy_mode="traefik", use_external_db=False)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.traefik.yaml"
    )


def test_build_compose_chain_standalone_with_external_db() -> None:
    assert (
        build_compose_chain(proxy_mode="standalone", use_external_db=True)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml:compose.external.yaml"
    )


def test_render_dev_env_writes_full_env(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "ENVIRONMENT=development" in env
    assert "COMPOSE_PROJECT_NAME=webtrees" in env
    assert "PHP_VERSION=8.5" in env
    assert "WEBTREES_VERSION=2.2.6" in env
    assert "WEBTREES_NGINX_VERSION=1.28-r1" in env
    assert "MARIADB_PASSWORD=devpw" in env
    assert "MARIADB_ROOT_PASSWORD=rootpw" in env
    assert "USE_EXISTING_DB=0" in env
    assert "LOCAL_USER_ID=1000" in env
    assert "APP_PORT=50010" in env
    assert "PMA_PORT=50011" in env
    assert "compose.publish.yaml" in env
    assert "compose.traefik.yaml" not in env
    assert "ENFORCE_HTTPS=FALSE" in env


def test_render_dev_env_traefik_drops_app_port(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path, proxy_mode="traefik",
                 dev_domain="webtrees.example.org", app_port=None, pma_port=None)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.traefik.yaml" in env
    assert "compose.publish.yaml" not in env
    assert "APP_PORT" not in env
    assert "PMA_PORT" not in env
    assert "ENFORCE_HTTPS=TRUE" in env


def test_render_dev_env_external_db_appends_compose_file(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path, use_external_db=True, mariadb_host="external-db.local")
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.external.yaml" in env
    assert "MARIADB_HOST=external-db.local" in env


def test_render_dev_env_rejects_traefik_without_domain(tmp_path: Path, catalog: Catalog) -> None:
    """Traefik mode demands a non-empty dev_domain."""
    args = _args(work_dir=tmp_path, proxy_mode="traefik", dev_domain="",
                 app_port=None, pma_port=None)
    with pytest.raises(ValueError, match="dev_domain"):
        render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                       generated_at=datetime(2026, 5, 12, 12, 0, 0))


def test_collect_dev_inputs_standalone_default_path() -> None:
    """All defaults accepted via empty stdin lines -> returns a populated DevArgs."""
    # Order of prompts: traefik? -> app_port -> pma_port -> dev_domain -> use_existing_db
    # -> use_external_db -> mariadb_root_password -> mariadb_database -> mariadb_user
    # -> mariadb_password
    stdin = StringIO("\n" * 16)  # 16 newlines covers every prompt with the default
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.proxy_mode == "standalone"
    assert args.app_port == 50010
    assert args.pma_port == 50011
    assert args.dev_domain == "192.168.1.50:50010"
    assert args.use_existing_db is False
    assert args.use_external_db is False
    assert args.mariadb_host == "db"
    assert args.local_user_id == 1000
    assert args.local_user_name == "dev"


def test_collect_dev_inputs_traefik_uses_dev_domain() -> None:
    """traefik branch skips port prompts and uses dev_domain only."""
    # Prompts after traefik=Y: dev_domain -> use_existing -> use_external -> 4x db creds.
    stdin = StringIO("y\nwebtrees.example.com\n\n\nrootpw\nwt\nwt_user\nwt_pw\n")
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.proxy_mode == "traefik"
    assert args.dev_domain == "webtrees.example.com"
    assert args.app_port is None
    assert args.pma_port is None
    assert args.mariadb_root_password == "rootpw"
    assert args.mariadb_user == "wt_user"


def test_collect_dev_inputs_external_db_asks_host() -> None:
    """use_external_db=Y triggers the mariadb_host prompt."""
    # Standalone, defaults for ports + domain, default no on existing-db,
    # YES on external-db, host=external-db.local, then 4x db creds.
    stdin = StringIO(
        "\n"                            # traefik? N
        "\n\n\n"                        # app/pma/dev_domain defaults
        "\n"                            # use_existing_db default N
        "y\n"                           # use_external_db Y
        "external-db.local\n"           # mariadb_host
        "rootpw\nwt\nwt_user\nwt_pw\n"  # creds
    )
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.use_external_db is True
    assert args.mariadb_host == "external-db.local"


def test_collect_dev_inputs_uses_existing_env_values() -> None:
    """If a previous .env exists, its values become the defaults."""
    existing = {
        "APP_PORT": "55555",
        "MARIADB_PASSWORD": "old-secret",
        "MARIADB_USER": "old_user",
    }
    stdin = StringIO("\n" * 16)
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing=existing,
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.app_port == 55555
    assert args.mariadb_password == "old-secret"
    assert args.mariadb_user == "old_user"


def test_collect_dev_inputs_rejects_non_numeric_port_in_env() -> None:
    """A legacy .env with APP_PORT=abc surfaces a PromptError, not a stack trace."""
    from webtrees_installer.prompts import PromptError
    existing = {"APP_PORT": "not-a-port"}
    with pytest.raises(PromptError, match="APP_PORT"):
        collect_dev_inputs(
            work_dir=Path("/work"), force=False,
            existing=existing,
            host_info=_HOST,
            stdin=StringIO("\n" * 16), stdout=StringIO(),
        )


def test_collect_dev_inputs_rejects_non_numeric_port_at_prompt() -> None:
    """Garbage at the port prompt surfaces a PromptError."""
    from webtrees_installer.prompts import PromptError
    stdin = StringIO("\nbananas\n")
    with pytest.raises(PromptError, match="not a number"):
        collect_dev_inputs(
            work_dir=Path("/work"), force=False,
            existing={},
            host_info=_HOST,
            stdin=stdin, stdout=StringIO(),
        )


_LIVE_CATALOG = Catalog(
    php_entries=(PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),),
    nginx_tag="1.28-r1",
    installer_version="0.1.0",
)


@pytest.fixture(autouse=True)
def silence_dev_runtime(tmp_path_factory, monkeypatch):
    """Stub the host-facing bits so dev-flow tests stay hermetic."""
    fake_manifest = tmp_path_factory.mktemp("manifest")
    monkeypatch.setenv("WEBTREES_INSTALLER_MANIFEST_DIR", str(fake_manifest))
    with patch("webtrees_installer.dev_flow.check_prerequisites"), \
         patch("webtrees_installer.dev_flow.load_catalog", return_value=_LIVE_CATALOG), \
         patch("webtrees_installer.dev_flow._detect_host_info",
               return_value=HostInfo(uid=1000, username="dev", primary_ip="10.0.0.5")), \
         patch("webtrees_installer.dev_flow._compose") as compose_mock:
        compose_mock.return_value = __import__("subprocess").CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        yield compose_mock


def test_run_dev_non_interactive_writes_env_and_pulls(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / ".env").is_file()
    assert (tmp_path / "persistent" / "database").is_dir()
    assert (tmp_path / "persistent" / "media").is_dir()
    assert (tmp_path / "app").is_dir()


def test_run_dev_invokes_compose_pull_and_install(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    # Reach into the autouse fixture's compose mock.
    with patch("webtrees_installer.dev_flow._compose") as compose_mock:
        import subprocess as _sp
        compose_mock.return_value = _sp.CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        run_dev(args, stdin=StringIO(), stdout=StringIO())

    invocations = [c.args[0] for c in compose_mock.call_args_list]
    assert ["compose", "pull"] in invocations
    assert any(
        inv[:3] == ["compose", "run", "--rm"] and "buildbox" in inv
        for inv in invocations
    )


def test_run_dev_fails_cleanly_when_compose_pull_breaks(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.dev_flow._compose") as compose_mock:
        import subprocess as _sp
        compose_mock.return_value = _sp.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="pull error",
        )
        exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 4


def test_run_dev_aborts_on_existing_files_without_force(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    (tmp_path / ".env").write_text("X=1")
    args = _args(work_dir=tmp_path, force=False)
    from webtrees_installer.prereq import PrereqError
    with pytest.raises(PrereqError):
        run_dev(args, stdin=StringIO(), stdout=StringIO())
