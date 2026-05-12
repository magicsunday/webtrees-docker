"""Command-line entry point for webtrees-installer."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from webtrees_installer import __version__
from webtrees_installer.flow import StandaloneArgs, run_standalone
from webtrees_installer.prereq import PrereqError
from webtrees_installer.prompts import PromptError
from webtrees_installer.stack import StackError


def build_parser() -> argparse.ArgumentParser:
    """Return the top-level argument parser."""
    parser = argparse.ArgumentParser(
        prog="webtrees-installer",
        description="Wizard for setting up a self-hosted webtrees stack.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"webtrees-installer {__version__}",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Skip prompts; every required answer must be passed as a flag.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing compose.yaml / .env without prompting.",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path("/work"),
        help="Target directory for the generated files (default: /work).",
    )
    parser.add_argument(
        "--edition",
        choices=["core", "full"],
        help="Image edition to write into compose.yaml.",
    )
    parser.add_argument(
        "--proxy",
        choices=["standalone", "traefik"],
        dest="proxy_mode",
        help="Reverse-proxy mode (default: standalone).",
    )
    parser.add_argument(
        "--port",
        type=int,
        dest="app_port",
        help="Host port for nginx (standalone mode only).",
    )
    parser.add_argument(
        "--domain",
        help="Public domain (Traefik mode only).",
    )
    parser.add_argument(
        "--admin-user",
        help="Username for the headless admin-bootstrap.",
    )
    parser.add_argument(
        "--admin-email",
        help="Email for the headless admin-bootstrap.",
    )
    parser.add_argument(
        "--no-admin",
        action="store_true",
        help="Skip the admin-bootstrap; rely on the browser setup wizard.",
    )
    parser.add_argument(
        "--no-up",
        action="store_true",
        help="Write files but do not run `docker compose up -d`.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns the process exit code."""
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        # argparse raises SystemExit for --version / --help after printing;
        # surface the status as a return value so callers (and tests) can
        # observe it without the interpreter aborting.
        return int(exc.code or 0)

    admin_bootstrap: bool | None
    if args.no_admin:
        admin_bootstrap = False
    elif args.admin_user is not None:
        admin_bootstrap = True
    else:
        admin_bootstrap = None

    flow_args = StandaloneArgs(
        work_dir=args.work_dir,
        interactive=not args.non_interactive,
        edition=args.edition,
        proxy_mode=args.proxy_mode,
        app_port=args.app_port,
        domain=args.domain,
        admin_bootstrap=admin_bootstrap,
        admin_user=args.admin_user,
        admin_email=args.admin_email,
        force=args.force,
        no_up=args.no_up,
    )

    try:
        return run_standalone(flow_args, stdin=sys.stdin, stdout=sys.stdout)
    except StackError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 3
    except (PrereqError, PromptError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
