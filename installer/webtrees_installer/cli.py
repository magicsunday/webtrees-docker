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
        "--mode",
        choices=["standalone", "dev"],
        default="standalone",
        help="Wizard mode: write a self-host compose.yaml (standalone) or "
             "configure the cloned repo for development (dev).",
    )
    parser.add_argument(
        "--pma-port",
        type=int,
        help="Host port for phpMyAdmin (dev mode, standalone proxy).",
    )
    parser.add_argument(
        "--dev-domain",
        help="Dev-domain string (dev mode); defaults to IP:APP_PORT in standalone.",
    )
    parser.add_argument(
        "--mariadb-root-password",
        help="MariaDB root password (dev mode).",
    )
    parser.add_argument(
        "--mariadb-database",
        help="MariaDB database name (dev mode).",
    )
    parser.add_argument(
        "--mariadb-user",
        help="MariaDB application user (dev mode).",
    )
    parser.add_argument(
        "--mariadb-password",
        help="MariaDB user password (dev mode).",
    )
    parser.add_argument(
        "--use-existing-db",
        action="store_true",
        help="Skip the schema init step in dev mode.",
    )
    parser.add_argument(
        "--use-external-db",
        action="store_true",
        help="Skip the bundled db service in dev mode and write compose.external.yaml into the chain.",
    )
    parser.add_argument(
        "--external-db-host",
        help="External MariaDB host (dev mode + --use-external-db).",
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

    if args.mode == "dev":
        from webtrees_installer.dev_flow import DevArgs, run_dev

        dev_args = DevArgs(
            work_dir=args.work_dir,
            interactive=not args.non_interactive,
            proxy_mode=args.proxy_mode or "standalone",
            dev_domain=args.dev_domain or "",
            app_port=args.app_port,
            pma_port=args.pma_port,
            mariadb_host=args.external_db_host or "db",
            mariadb_database=args.mariadb_database or "webtrees",
            mariadb_user=args.mariadb_user or "webtrees",
            mariadb_password=args.mariadb_password or "",
            mariadb_root_password=args.mariadb_root_password or "",
            use_existing_db=args.use_existing_db,
            use_external_db=args.use_external_db,
            local_user_id=0,
            local_user_name="",
            force=args.force,
        )
        try:
            return run_dev(dev_args, stdin=sys.stdin, stdout=sys.stdout)
        except StackError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 3
        except (PrereqError, PromptError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

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
