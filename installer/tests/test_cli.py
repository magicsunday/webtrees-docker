"""CLI smoke tests."""

from webtrees_installer import __version__
from webtrees_installer.cli import build_parser, main


def test_version_flag_prints_version(capsys):
    """--version prints the package version and exits 0."""
    exit_code = main(["--version"])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert __version__ in captured.out


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
