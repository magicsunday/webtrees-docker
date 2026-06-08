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
    _host_without_port,
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
        edition="full",
        proxy_mode="standalone",
        dev_domain="webtrees.localhost:50010",
        app_port=50010,
        pma_port=50011,
        external_db_host="db",
        mariadb_database="webtrees",
        mariadb_user="webtrees",
        mariadb_password="devpw",
        mariadb_root_password="rootpw",
        use_existing_db=False,
        use_external_db=False,
        local_user_id=1000,
        local_user_name="dev",
        host_work_dir="/host/workspace",
        enforce_https=True,
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
    # Test feeds enforce_https=True explicitly via _args default; the
    # render-layer test pins what the Jinja template does with that
    # value. The wizard-level smart-default (standalone → FALSE,
    # traefik → TRUE) is exercised in the run_dev / collect_dev_inputs
    # tests below, not here.
    assert "ENFORCE_HTTPS=TRUE" in env


def test_render_dev_env_no_https_opt_out(tmp_path: Path, catalog: Catalog) -> None:
    """`--no-https` (enforce_https=False) renders ENFORCE_HTTPS=FALSE in the dev .env."""
    args = _args(work_dir=tmp_path, enforce_https=False)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
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
    args = _args(work_dir=tmp_path, use_external_db=True, external_db_host="external-db.local")
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.external.yaml" in env
    assert "MARIADB_HOST=external-db.local" in env


def test_render_dev_env_rejects_traefik_without_domain(tmp_path: Path, catalog: Catalog) -> None:
    """Traefik mode demands a non-empty dev_domain.

    Raised as PromptError (not a bare ValueError) so a non-interactive run
    missing the flag exits 2 via the CLI translator instead of escaping as
    an uncaught traceback (exit 1).
    """
    from webtrees_installer.prompts import PromptError

    args = _args(work_dir=tmp_path, proxy_mode="traefik", dev_domain="",
                 app_port=None, pma_port=None)
    with pytest.raises(PromptError, match="dev_domain"):
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
    assert args.external_db_host == "db"
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
    """use_external_db=Y triggers the external-db host prompt."""
    # Standalone, defaults for ports + domain, default no on existing-db,
    # YES on external-db, host=external-db.local, then 4x db creds.
    stdin = StringIO(
        "\n"                            # traefik? N
        "\n\n\n"                        # app/pma/dev_domain defaults
        "\n"                            # use_existing_db default N
        "y\n"                           # use_external_db Y
        "external-db.local\n"           # external_db_host
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
    assert args.external_db_host == "external-db.local"


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
    # The retained password is reused as the default but must never be
    # echoed back to the terminal (clear-text-logging leak).
    assert "old-secret" not in stdout.getvalue()


def test_collect_dev_inputs_preserves_existing_enforce_https_true() -> None:
    """A previous ENFORCE_HTTPS=TRUE survives a re-render without --no-https."""
    existing = {"ENFORCE_HTTPS": "TRUE"}
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing=existing,
        host_info=_HOST,
        stdin=StringIO("\n" * 16), stdout=StringIO(),
    )
    assert args.enforce_https is True


def test_collect_dev_inputs_preserves_existing_enforce_https_false() -> None:
    """A previous ENFORCE_HTTPS=FALSE survives a re-render without --no-https."""
    existing = {"ENFORCE_HTTPS": "FALSE"}
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing=existing,
        host_info=_HOST,
        # The smart default for the standalone branch (which the empty
        # stdin steers towards via use_traefik=False) is FALSE — same
        # outcome as the env value here, but the env-vs-default
        # precedence is the contract being pinned: env wins.
        stdin=StringIO("\n" * 16), stdout=StringIO(),
    )
    assert args.enforce_https is False


def test_collect_dev_inputs_no_env_no_cli_standalone_defaults_false() -> None:
    """Smart default mirroring flow.py's #147 fix: with no .env, no
    CLI flag, and use_traefik=False at the prompt, enforce_https
    defaults to FALSE (standalone has no upstream TLS terminator).
    Empty stdin lines take each prompt's default — `use_traefik`
    defaults to False, so proxy_mode resolves to 'standalone'."""
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=StringIO("\n" * 16), stdout=StringIO(),
    )
    assert args.proxy_mode == "standalone"
    assert args.enforce_https is False


def test_collect_dev_inputs_no_env_no_cli_traefik_defaults_true() -> None:
    """Counterpart: use_traefik=True at the prompt resolves proxy_mode
    to 'traefik' and enforce_https defaults to TRUE (Traefik terminates
    TLS upstream). First prompt is `ask_yesno('Is a Traefik reverse
    proxy available?', default=False)` — feed 'y\\n' to override."""
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=StringIO("y\n" + "\n" * 16), stdout=StringIO(),
    )
    assert args.proxy_mode == "traefik"
    assert args.enforce_https is True


def test_collect_dev_inputs_no_https_overrides_existing_true() -> None:
    """`--no-https` (enforce_https=False) wins over an existing TRUE."""
    existing = {"ENFORCE_HTTPS": "TRUE"}
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing=existing,
        host_info=_HOST,
        enforce_https=False,  # operator passed --no-https
        stdin=StringIO("\n" * 16), stdout=StringIO(),
    )
    assert args.enforce_https is False


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


def test_run_dev_non_interactive_standalone_defaults_enforce_https_false(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """`--non-interactive --proxy standalone` without `--no-https`
    (enforce_https=None) defaults to ENFORCE_HTTPS=FALSE. dev_domain
    under standalone resolves to a LAN-IP-with-port form (no upstream
    TLS terminator), and defaulting TRUE would emit a 301 to
    `https://<host>/` that nothing answers — same trap #147 fixed in
    the production flow."""
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path, enforce_https=None)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    env = (tmp_path / ".env").read_text()
    assert "ENFORCE_HTTPS=FALSE" in env


def test_run_dev_non_interactive_traefik_defaults_enforce_https_true(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """`--non-interactive --proxy traefik` without `--no-https`
    (enforce_https=None) keeps the TRUE default. Traefik terminates TLS
    upstream and forwards X-Forwarded-Proto=https; in-app links must
    match the public scheme."""
    from webtrees_installer.dev_flow import run_dev
    args = _args(
        work_dir=tmp_path,
        enforce_https=None,
        proxy_mode="traefik",
        dev_domain="webtrees.example.org",
        app_port=None,
        pma_port=None,
    )

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    env = (tmp_path / ".env").read_text()
    assert "ENFORCE_HTTPS=TRUE" in env


def test_run_dev_non_interactive_preserves_existing_enforce_https_false(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Re-render preservation also works on the non-interactive path."""
    from webtrees_installer.dev_flow import run_dev
    (tmp_path / ".env").write_text("ENFORCE_HTTPS=FALSE\n")
    args = _args(work_dir=tmp_path, enforce_https=None, force=True)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    env = (tmp_path / ".env").read_text()
    assert "ENFORCE_HTTPS=FALSE" in env


def test_run_dev_invokes_compose_pull_and_install(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Accept the autouse compose_mock directly instead of re-patching."""
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    run_dev(args, stdin=StringIO(), stdout=StringIO())

    invocations = [c.args[0] for c in silence_dev_runtime.call_args_list]
    # Issue #132: `compose pull --ignore-buildable` skips the
    # locally-built dev images (buildbox, phpfpm) that aren't in any
    # public registry, and a separate `compose build` step makes the
    # build output visible before the install-application run.
    assert ["compose", "pull", "--ignore-buildable"] in invocations
    assert ["compose", "build"] in invocations
    assert any(
        inv[:3] == ["compose", "run", "--rm"] and "buildbox" in inv
        for inv in invocations
    )


def test_run_dev_fails_cleanly_when_compose_pull_breaks(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Pull fails with rc=1 + stderr → exit 4 (build / install branches never run)."""
    import subprocess as _sp
    from webtrees_installer.dev_flow import run_dev

    silence_dev_runtime.side_effect = [
        _sp.CompletedProcess(args=[], returncode=1, stdout="", stderr="pull error"),
    ]
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 4
    invocations = [c.args[0] for c in silence_dev_runtime.call_args_list]
    assert invocations == [["compose", "pull", "--ignore-buildable"]]


def test_run_dev_fails_cleanly_when_install_breaks(
    tmp_path: Path, silence_dev_runtime
) -> None:
    """Pull + build succeed, install returns rc=1 → exit 4 (separate branch coverage)."""
    import subprocess as _sp
    from webtrees_installer.dev_flow import run_dev

    silence_dev_runtime.side_effect = [
        _sp.CompletedProcess(args=[], returncode=0, stdout="", stderr=""),  # pull
        _sp.CompletedProcess(args=[], returncode=0, stdout="", stderr=""),  # build
        _sp.CompletedProcess(args=[], returncode=1, stdout="", stderr="install boom"),
    ]
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 4
    invocations = [c.args[0] for c in silence_dev_runtime.call_args_list]
    assert invocations[0] == ["compose", "pull", "--ignore-buildable"]
    assert invocations[1] == ["compose", "build"]
    assert invocations[2][:3] == ["compose", "run", "--rm"]


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
    """Empty host_work_dir surfaces a PromptError, never writes the .env."""
    from webtrees_installer.prompts import PromptError

    args = _args(work_dir=tmp_path, host_work_dir="")
    with pytest.raises(PromptError, match="host_work_dir"):
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


def test_print_dev_banner_standalone_enforce_https_shows_warning_no_url() -> None:
    """Dev wizard mirror of test_print_banner_standalone_enforce_https_shows_warning_no_url
    in test_flow.py. Standalone proxy + ENFORCE_HTTPS=TRUE has no
    working browser URL in dev_flow either (same nginx no-`listen 443
    ssl` situation, same redirect loop, same SSL_ERROR_RX_RECORD_TOO_LONG).
    Banner MUST suppress the https://… URL and surface the
    reverse-proxy requirement + --no-https escape hatch. Pins #118
    contract on the dev wizard's banner so a future refactor cannot
    silently restore the misleading URL on either flow."""
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    _print_dev_banner(stdout=out, args=_args(enforce_https=True, proxy_mode="standalone"))
    text = out.getvalue()
    assert "https://webtrees.localhost:50010" not in text, (
        "must not advertise an https:// URL that hits a plain-HTTP socket"
    )
    assert "Direct browser access not possible" in text
    assert "TLS-terminating reverse proxy" in text
    assert "--no-https" in text


def test_print_dev_banner_standalone_no_https_shows_http_url() -> None:
    """Dev wizard: standalone + ENFORCE_HTTPS=FALSE renders plain HTTP
    on the published port; banner shows `http://` so the dev URL works
    when pasted into a browser."""
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    _print_dev_banner(stdout=out, args=_args(enforce_https=False, proxy_mode="standalone"))
    text = out.getvalue()
    assert "http://webtrees.localhost:50010/" in text
    assert "https://webtrees.localhost" not in text


def test_print_dev_banner_standalone_no_https_includes_security_note() -> None:
    """Dev wizard parity with the production banner: the symmetric
    plaintext-HTTP advisory must accompany the http://… URL so a
    developer running on a shared dev VM / Wi-Fi sees the cleartext
    trade-off they inherited from the now-default ENFORCE_HTTPS=FALSE
    under standalone."""
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    _print_dev_banner(stdout=out, args=_args(enforce_https=False, proxy_mode="standalone"))
    assert "HTTPS is off" in out.getvalue()


def test_print_dev_banner_standalone_with_https_omits_security_note() -> None:
    """The plaintext-HTTP advisory belongs to the FALSE branch only.
    Standalone + ENFORCE_HTTPS=TRUE fires the reverse-proxy warning
    instead — emitting both would contradict the operator's HTTPS
    choice."""
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    _print_dev_banner(stdout=out, args=_args(enforce_https=True, proxy_mode="standalone"))
    assert "HTTPS is off" not in out.getvalue()


def test_print_dev_banner_traefik_shows_https_domain() -> None:
    """Dev wizard: non-standalone proxy (traefik) terminates TLS at
    the fronting proxy; banner shows https://<dev_domain>/ regardless
    of ENFORCE_HTTPS."""
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    _print_dev_banner(
        stdout=out,
        args=_args(enforce_https=True, proxy_mode="traefik", dev_domain="wt.dev.example.com"),
    )
    text = out.getvalue()
    assert "https://wt.dev.example.com/" in text


def test_print_dev_banner_includes_what_next_section() -> None:
    """Dev banner must also surface the re-entry guide so the helper
    call doesn't regress in only one of the two flows. Pins the
    dev_flow.py integration of #119."""
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    _print_dev_banner(stdout=out, args=_args(enforce_https=False, proxy_mode="standalone"))
    text = out.getvalue()
    assert "/install | bash" in text
    assert "/upgrade | bash" in text
    assert "/switch | bash" in text


def test_print_dev_banner_emits_lan_url_when_host_lan_ip_set() -> None:
    """Dev banner parity with production banner (#138): when HOST_LAN_IP
    is set, the dev wizard emits an additional `Webtrees URL: http://
    <LAN-IP>:<port>/` line so a developer SSHing into a remote dev VM
    gets a cross-machine-reachable URL alongside the operator-chosen
    dev_domain URL. Skips localhost line because dev_domain already
    covers the host-local path."""
    import os
    from unittest.mock import patch
    from webtrees_installer.dev_flow import _print_dev_banner
    out = StringIO()
    with patch.dict(os.environ, {"HOST_LAN_IP": "192.168.178.25"}, clear=False):
        _print_dev_banner(
            stdout=out,
            args=_args(enforce_https=False, proxy_mode="standalone"),
        )
    text = out.getvalue()
    assert "http://192.168.178.25:" in text
    # dev_domain URL still present
    assert "http://webtrees.localhost:50010/" in text


# ──────────────────────────────────────────────────────────────────────
# _host_without_port (phpMyAdmin URL host derivation)
# ──────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("192.168.1.50:50010", "192.168.1.50"),
        ("webtrees.localhost:50010", "webtrees.localhost"),
        ("webtrees.example.org", "webtrees.example.org"),
        ("[fd00::1]:50010", "[fd00::1]"),
        ("[fd00::1]", "[fd00::1]"),
        ("fd00::1", "fd00::1"),  # bracket-less IPv6: best-effort, left intact
    ],
)
def test_host_without_port(value: str, expected: str) -> None:
    assert _host_without_port(value) == expected


def test_dev_banner_phpmyadmin_url_handles_ipv6(catalog: Catalog) -> None:
    """An IPv6 dev_domain must not be split into '[fd00' for the PMA URL."""
    from webtrees_installer.dev_flow import _print_dev_banner

    out = StringIO()
    _print_dev_banner(
        stdout=out,
        args=_args(proxy_mode="standalone", dev_domain="[fd00::1]:50010", pma_port=50011),
    )
    assert "phpMyAdmin URL: http://[fd00::1]:50011/" in out.getvalue()


# ──────────────────────────────────────────────────────────────────────
# Exit-code contract: missing required dev input → PromptError (→ exit 2)
# ──────────────────────────────────────────────────────────────────────


def test_render_dev_env_rejects_standalone_without_ports(
    tmp_path: Path, catalog: Catalog
) -> None:
    """`--mode dev --non-interactive --proxy standalone` without ports must
    surface a PromptError, not a bare ValueError that escapes as a
    traceback (exit 1 instead of the documented exit 2)."""
    from webtrees_installer.prompts import PromptError

    args = _args(work_dir=tmp_path, proxy_mode="standalone", app_port=None, pma_port=None)
    with pytest.raises(PromptError, match="app_port and pma_port"):
        render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                       generated_at=datetime(2026, 5, 12, 12, 0, 0))


# ──────────────────────────────────────────────────────────────────────
# EDITION persistence (GH-114 F: survive a ./switch dev round-trip)
# ──────────────────────────────────────────────────────────────────────


def test_render_dev_env_persists_edition(tmp_path: Path, catalog: Catalog) -> None:
    """The dev .env carries EDITION so `./switch standalone` can restore it."""
    args = _args(work_dir=tmp_path, edition="core")
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))
    env_text = (tmp_path / ".env").read_text()
    assert "EDITION=core" in env_text


def test_collect_dev_inputs_carries_existing_edition_forward() -> None:
    """A prior .env's EDITION is preserved (not reset) through the dev flow."""
    stdin = StringIO("\n" * 16)
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={"EDITION": "core"},
        host_info=_HOST,
        stdin=stdin, stdout=StringIO(),
    )
    assert args.edition == "core"


def test_collect_dev_inputs_defaults_edition_to_full_when_absent() -> None:
    """No prior EDITION (fresh dev install) defaults to full."""
    stdin = StringIO("\n" * 16)
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=StringIO(),
    )
    assert args.edition == "full"
