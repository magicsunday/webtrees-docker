"""CLI smoke tests."""

from unittest.mock import patch

from webtrees_installer import __version__
from webtrees_installer.cli import build_parser, main
from webtrees_installer.prereq import PrereqError
from webtrees_installer.stack import StackError


def test_version_flag_prints_version(capsys):
    """--version prints the package version and exits 0."""
    exit_code = main(["--version"])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert __version__ in captured.out


def test_main_returns_2_on_prereq_error(capsys):
    """PrereqError out of run_standalone → exit 2 + stderr message."""
    with patch("webtrees_installer.cli.run_standalone", side_effect=PrereqError("missing")):
        exit_code = main(["--non-interactive", "--force", "--no-up", "--no-admin",
                          "--edition", "core", "--proxy", "standalone", "--port", "8080"])

    captured = capsys.readouterr()
    assert exit_code == 2
    assert "missing" in captured.err


def test_main_returns_3_on_stack_error(capsys):
    """StackError out of run_standalone → exit 3 + stderr message."""
    with patch("webtrees_installer.cli.run_standalone", side_effect=StackError("nginx down")):
        exit_code = main(["--non-interactive", "--force", "--no-admin",
                          "--edition", "core", "--proxy", "standalone", "--port", "8080"])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert "nginx down" in captured.err


def test_parser_carries_all_non_interactive_flags():
    """Every non-interactive flag is present so the smoke-test CI job can drive it."""
    parser = build_parser()
    args = parser.parse_args(
        [
            "--non-interactive",
            "--force",
            "--no-up",
            "--no-admin",
            "--edition", "core",
            "--proxy", "standalone",
            "--port", "8080",
        ]
    )
    assert args.non_interactive is True
    assert args.force is True
    assert args.no_up is True
    assert args.no_admin is True
    assert args.edition == "core"
    assert args.proxy_mode == "standalone"
    assert args.app_port == 8080


def test_parser_carries_dev_mode_and_dev_flags():
    parser = build_parser()
    args = parser.parse_args(
        [
            "--mode", "dev",
            "--non-interactive",
            "--force",
            "--proxy", "standalone",
            "--port", "50010",
            "--pma-port", "50011",
            "--dev-domain", "webtrees.localhost:50010",
            "--mariadb-root-password", "rootpw",
            "--mariadb-database", "wt",
            "--mariadb-user", "wt_user",
            "--mariadb-password", "wt_pw",
            "--local-user-id", "1000",
            "--local-user-name", "rico",
        ]
    )
    assert args.mode == "dev"
    assert args.non_interactive is True
    assert args.force is True
    assert args.proxy_mode == "standalone"
    assert args.app_port == 50010
    assert args.pma_port == 50011
    assert args.dev_domain == "webtrees.localhost:50010"
    assert args.mariadb_root_password == "rootpw"
    assert args.mariadb_database == "wt"
    assert args.mariadb_user == "wt_user"
    assert args.mariadb_password == "wt_pw"
    assert args.local_user_id == 1000
    assert args.local_user_name == "rico"
    # The two boolean toggles default to False when not on the CLI.
    assert args.use_existing_db is False
    assert args.use_external_db is False


def test_parser_dev_external_db_toggles():
    """`--use-existing-db` / `--use-external-db` flip to True; --external-db-host binds."""
    parser = build_parser()
    args = parser.parse_args(
        [
            "--mode", "dev",
            "--use-existing-db",
            "--use-external-db",
            "--external-db-host", "external-db.local",
        ]
    )
    assert args.use_existing_db is True
    assert args.use_external_db is True
    assert args.external_db_host == "external-db.local"


def test_parser_carries_demo_flags():
    parser = build_parser()
    args = parser.parse_args([
        "--non-interactive", "--no-admin", "--edition", "full",
        "--proxy", "standalone", "--port", "8080", "--demo", "--demo-seed", "7",
    ])
    assert args.demo is True
    assert args.demo_seed == 7


def test_main_returns_2_when_pretty_urls_combined_with_dev_mode(capsys):
    """`--pretty-urls` is standalone-only; dev mode rejects it with exit 2 + clear message."""
    exit_code = main([
        "--mode", "dev",
        "--non-interactive", "--force",
        "--proxy", "standalone", "--port", "50010",
        "--pretty-urls",
    ])

    captured = capsys.readouterr()
    assert exit_code == 2
    assert "--pretty-urls is standalone-only" in captured.err
    assert "WEBTREES_REWRITE_URLS" in captured.err


def test_main_accepts_pretty_urls_in_standalone_mode():
    """The mode-compatibility check fires only for dev mode — standalone must pass through."""
    with patch("webtrees_installer.cli.run_standalone", return_value=0) as run_mock:
        exit_code = main([
            "--non-interactive", "--force", "--no-up", "--no-admin",
            "--edition", "core", "--proxy", "standalone", "--port", "28080",
            "--pretty-urls",
        ])

    assert exit_code == 0
    assert run_mock.called
    # The StandaloneArgs is the single positional arg.
    flow_args = run_mock.call_args.args[0]
    assert flow_args.pretty_urls is True


def test_main_silently_accepts_dev_only_flag_in_standalone_mode():
    """Symmetric half of the mode-compat rule: dev-only flags pass through standalone untouched."""
    with patch("webtrees_installer.cli.run_standalone", return_value=0) as run_mock:
        exit_code = main([
            "--non-interactive", "--force", "--no-up", "--no-admin",
            "--edition", "core", "--proxy", "standalone", "--port", "28080",
            "--pma-port", "50011",
        ])

    assert exit_code == 0
    assert run_mock.called


def test_main_returns_2_when_no_https_combined_with_proxy_traefik(capsys):
    """`--no-https --proxy traefik` is internally inconsistent (the rendered
    router still terminates TLS via websecure/tls=true labels). Rejected with
    exit 2 + clear message pointing at standalone as the alternative."""
    exit_code = main([
        "--non-interactive", "--force", "--no-up", "--no-admin",
        "--edition", "core",
        "--proxy", "traefik", "--domain", "webtrees.example.com",
        "--no-https",
    ])

    captured = capsys.readouterr()
    assert exit_code == 2
    assert "--no-https is incompatible with --proxy traefik" in captured.err
    assert "--proxy standalone" in captured.err
    # Pin the shared "why" clause from prompts.TRAEFIK_TLS_INCOMPAT_REASON
    # so a silent rename or drift between the two guard call-sites fails loud.
    assert "websecure entrypoint + tls=true" in captured.err


def test_main_accepts_no_https_with_proxy_standalone():
    """The validator targets only the traefik combination; --no-https on
    standalone (the documented local-no-TLS use case) must keep working."""
    with patch("webtrees_installer.cli.run_standalone", return_value=0) as run_mock:
        exit_code = main([
            "--non-interactive", "--force", "--no-up", "--no-admin",
            "--edition", "core",
            "--proxy", "standalone", "--port", "28080",
            "--no-https",
        ])

    assert exit_code == 0
    assert run_mock.called
    flow_args = run_mock.call_args.args[0]
    assert flow_args.enforce_https is False


def test_main_traefik_network_default_passes_through():
    """`--traefik-network` defaults to `traefik` and reaches
    StandaloneArgs unchanged when omitted."""
    with patch("webtrees_installer.cli.run_standalone", return_value=0) as run_mock:
        exit_code = main([
            "--non-interactive", "--force", "--no-up", "--no-admin",
            "--edition", "core",
            "--proxy", "traefik", "--domain", "webtrees.example.com",
        ])

    assert exit_code == 0
    assert run_mock.called
    flow_args = run_mock.call_args.args[0]
    assert flow_args.traefik_network == "traefik"


def test_main_traefik_network_custom_value_propagates():
    """Operator on a Traefik network named `proxy` (or similar) passes
    the flag and the rendered stack joins that network instead."""
    with patch("webtrees_installer.cli.run_standalone", return_value=0) as run_mock:
        exit_code = main([
            "--non-interactive", "--force", "--no-up", "--no-admin",
            "--edition", "core",
            "--proxy", "traefik", "--domain", "webtrees.example.com",
            "--traefik-network", "proxy",
        ])

    assert exit_code == 0
    flow_args = run_mock.call_args.args[0]
    assert flow_args.traefik_network == "proxy"


def test_parser_pretty_urls_flag_defaults_off_and_flips_to_true():
    """`--pretty-urls` is opt-in: absent → False, present → True."""
    parser = build_parser()
    default_args = parser.parse_args([
        "--non-interactive", "--no-admin", "--edition", "core",
        "--proxy", "standalone", "--port", "28080",
    ])
    assert default_args.pretty_urls is False

    on_args = parser.parse_args([
        "--non-interactive", "--no-admin", "--edition", "core",
        "--proxy", "standalone", "--port", "28080", "--pretty-urls",
    ])
    assert on_args.pretty_urls is True
