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
