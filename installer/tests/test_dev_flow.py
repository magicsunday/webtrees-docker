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


_HOST = HostInfo(uid=1000, username="dev", primary_ip="192.168.1.50",
                 work_dir="/host/workspace")


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),),
        nginx_tag="1.30-r1",
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
        host_work_dir="/host/workspace",
        force=True,
        no_up=False,
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
    assert "COMPOSE_PROJECT_NAME=" not in env
    assert "PHP_VERSION=8.5" in env
    assert "WEBTREES_VERSION=2.2.6" in env
    assert "WEBTREES_NGINX_VERSION=1.30-r1" in env
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


def test_collect_dev_inputs_threads_no_up_through() -> None:
    """A caller-supplied ``no_up=True`` survives the interactive prompt loop.

    Regression: before threading the flag, the collector hard-coded
    ``no_up=False`` in the returned DevArgs, so an interactive ``--no-up``
    invocation silently lost the flag before the wizard reached the
    compose-pull / composer-install step.
    """
    stdin = StringIO("\n" * 16)
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=True,
        existing={},
        host_info=_HOST,
        no_up=True,
        stdin=stdin, stdout=StringIO(),
    )
    assert args.no_up is True
    assert args.force is True


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
    nginx_tag="1.30-r1",
    installer_version="0.1.0",
)


@pytest.fixture(autouse=True)
def _manifest_env(tmp_path_factory, monkeypatch):
    """Always-on: point WEBTREES_INSTALLER_MANIFEST_DIR at a real (empty) dir.

    Resolver tests (and the host-info helper test) inherit just this so
    `resolve_manifest_dir` succeeds without populating the env outside.
    """
    fake_manifest = tmp_path_factory.mktemp("manifest")
    monkeypatch.setenv("WEBTREES_INSTALLER_MANIFEST_DIR", str(fake_manifest))


@pytest.fixture
def silence_dev_runtime():
    """Opt-in: stub everything an orchestrator test needs.

    Tests that exercise `_detect_host_info` directly skip this fixture
    so they hit the real implementation.
    """
    with patch("webtrees_installer.dev_flow.check_prerequisites"), \
         patch("webtrees_installer.dev_flow.load_catalog", return_value=_LIVE_CATALOG), \
         patch("webtrees_installer.dev_flow._detect_host_info",
               return_value=HostInfo(uid=1000, username="dev", primary_ip="10.0.0.5",
                                     work_dir="/host/workspace")), \
         patch("webtrees_installer.dev_flow._compose") as compose_mock:
        compose_mock.return_value = __import__("subprocess").CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        yield compose_mock


def test_run_dev_non_interactive_writes_env_and_pulls(
    tmp_path: Path, silence_dev_runtime
) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / ".env").is_file()
    assert (tmp_path / "persistent" / "database").is_dir()
    assert (tmp_path / "persistent" / "media").is_dir()
    assert (tmp_path / "app").is_dir()


def test_run_dev_invokes_compose_pull_and_install(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Accept the autouse compose_mock directly instead of re-patching."""
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    run_dev(args, stdin=StringIO(), stdout=StringIO())

    invocations = [c.args[0] for c in silence_dev_runtime.call_args_list]
    assert ["compose", "pull"] in invocations
    assert any(
        inv[:3] == ["compose", "run", "--rm"] and "buildbox" in inv
        for inv in invocations
    )


def test_run_dev_fails_cleanly_when_compose_pull_breaks(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Pull fails with rc=1 + stderr → exit 4 (install branch never runs)."""
    import subprocess as _sp
    from webtrees_installer.dev_flow import run_dev

    silence_dev_runtime.side_effect = [
        _sp.CompletedProcess(args=[], returncode=1, stdout="", stderr="pull error"),
    ]
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 4
    invocations = [c.args[0] for c in silence_dev_runtime.call_args_list]
    assert invocations == [["compose", "pull"]]


def test_run_dev_fails_cleanly_when_install_breaks(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Pull succeeds, install returns rc=1 → exit 4 (separate branch coverage)."""
    import subprocess as _sp
    from webtrees_installer.dev_flow import run_dev

    silence_dev_runtime.side_effect = [
        _sp.CompletedProcess(args=[], returncode=0, stdout="", stderr=""),
        _sp.CompletedProcess(args=[], returncode=1, stdout="", stderr="install boom"),
    ]
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 4
    invocations = [c.args[0] for c in silence_dev_runtime.call_args_list]
    assert invocations[0] == ["compose", "pull"]
    assert invocations[1][:3] == ["compose", "run", "--rm"]


def test_run_dev_aborts_on_existing_files_without_force(
    tmp_path: Path, silence_dev_runtime
) -> None:
    from webtrees_installer.dev_flow import run_dev
    (tmp_path / ".env").write_text("X=1")
    args = _args(work_dir=tmp_path, force=False)
    from webtrees_installer.prereq import PrereqError
    with pytest.raises(PrereqError):
        run_dev(args, stdin=StringIO(), stdout=StringIO())


def test_detect_host_info_falls_back_when_socket_fails() -> None:
    """No-network host → primary_ip falls back to 127.0.0.1 without raising."""
    from webtrees_installer.dev_flow import _detect_host_info

    with patch("webtrees_installer.dev_flow.socket.socket") as sock_factory:
        sock_factory.return_value.connect.side_effect = OSError("network unreachable")
        info = _detect_host_info()

    assert info.primary_ip == "127.0.0.1"


def test_detect_host_info_reads_work_dir_env(monkeypatch) -> None:
    """WORK_DIR env var (set by the launcher) flows into HostInfo.work_dir."""
    from webtrees_installer.dev_flow import _detect_host_info

    monkeypatch.setenv("WORK_DIR", "/srv/webtrees")
    info = _detect_host_info()

    assert info.work_dir == "/srv/webtrees"


def test_detect_host_info_falls_back_to_cwd_without_work_dir(monkeypatch) -> None:
    """Direct-host invocation (no WORK_DIR env) falls back to os.getcwd()."""
    from webtrees_installer.dev_flow import _detect_host_info

    monkeypatch.delenv("WORK_DIR", raising=False)
    monkeypatch.setattr("webtrees_installer.dev_flow.os.getcwd",
                        lambda: "/fallback/cwd")
    info = _detect_host_info()

    assert info.work_dir == "/fallback/cwd"


def test_render_dev_env_writes_work_dir_line(tmp_path: Path, catalog: Catalog) -> None:
    """The rendered .env carries WORK_DIR="<host-path>" for compose to pick up."""
    args = _args(work_dir=tmp_path, host_work_dir=str(tmp_path))
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert f'WORK_DIR="{tmp_path}"' in env


def test_render_dev_env_quotes_work_dir(tmp_path: Path, catalog: Catalog) -> None:
    """WORK_DIR value is wrapped in double quotes.

    Compose's env-file parser strips ``#...`` inline comments and trims
    trailing whitespace from unquoted values. A host path containing
    either character would silently truncate, so the template must emit
    the value quoted regardless of the path content.
    """
    args = _args(work_dir=tmp_path, host_work_dir="/srv/projects/wt")
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    # The exact line: quoted on both sides, no bare value form.
    assert 'WORK_DIR="/srv/projects/wt"' in env
    assert "WORK_DIR=/srv/projects/wt\n" not in env


def test_render_dev_env_rejects_empty_host_work_dir(tmp_path: Path, catalog: Catalog) -> None:
    """Empty host_work_dir surfaces a ValueError, never writes the .env."""
    args = _args(work_dir=tmp_path, host_work_dir="")
    with pytest.raises(ValueError, match="host_work_dir"):
        render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                       generated_at=datetime(2026, 5, 12, 12, 0, 0))


def test_run_dev_no_up_skips_compose(tmp_path: Path, silence_dev_runtime) -> None:
    """--no-up writes .env + persistent dirs and returns 0 without touching compose."""
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path, no_up=True)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / ".env").is_file()
    assert (tmp_path / "persistent" / "database").is_dir()
    # Compose must never have been invoked when --no-up is set.
    assert silence_dev_runtime.call_count == 0


def test_run_dev_interactive_preserves_no_up(tmp_path: Path, silence_dev_runtime) -> None:
    """Interactive ``--no-up`` round-trips through the prompt loop.

    Regression: ``collect_dev_inputs`` used to overwrite ``no_up`` with
    ``False`` when reassigning ``args``, so the wizard ran compose-pull
    + composer-install even though the caller asked for --no-up.
    """
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path, interactive=True, no_up=True, force=True)

    exit_code = run_dev(args, stdin=StringIO("\n" * 16), stdout=StringIO())

    assert exit_code == 0
    # Compose must never have been touched in the interactive --no-up flow.
    assert silence_dev_runtime.call_count == 0


def test_run_dev_fills_host_work_dir_from_env(tmp_path: Path, monkeypatch,
                                              silence_dev_runtime) -> None:
    """When the CLI hands DevArgs(host_work_dir=None) the env var fills it in."""
    from webtrees_installer.dev_flow import run_dev
    # silence_dev_runtime patches _detect_host_info, so the env var only
    # reaches the .env via the patched HostInfo.work_dir field — assert
    # the wiring there.
    args = _args(work_dir=tmp_path, host_work_dir=None, no_up=True)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    env = (tmp_path / ".env").read_text()
    assert 'WORK_DIR="/host/workspace"' in env
