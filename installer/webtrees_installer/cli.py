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

    dev_group = parser.add_argument_group(
        "Dev mode (--mode dev)",
        "Flags consumed by the dev-flow orchestrator. Ignored in standalone mode.",
    )
    dev_group.add_argument(
        "--pma-port",
        type=int,
        help="Host port for phpMyAdmin (dev mode, standalone proxy).",
    )
    dev_group.add_argument(
        "--dev-domain",
        help="Dev-domain string (dev mode); defaults to IP:APP_PORT in standalone.",
    )
    dev_group.add_argument(
        "--mariadb-root-password",
        help="MariaDB root password (dev mode).",
    )
    dev_group.add_argument(
        "--mariadb-database",
        help="MariaDB database name (dev mode).",
    )
    dev_group.add_argument(
        "--mariadb-user",
        help="MariaDB application user (dev mode).",
    )
    dev_group.add_argument(
        "--mariadb-password",
        help="MariaDB user password (dev mode).",
    )
    dev_group.add_argument(
        "--use-existing-db",
        action="store_true",
        help="Skip the schema init step in dev mode.",
    )
    dev_group.add_argument(
        "--use-external-db",
        action="store_true",
        help="Skip the bundled db service in dev mode and write compose.external.yaml into the chain.",
    )
    dev_group.add_argument(
        "--external-db-host",
        help="External MariaDB host (dev mode + --use-external-db).",
    )
    dev_group.add_argument(
        "--local-user-id",
        type=int,
        help="Host UID to write into LOCAL_USER_ID. Inside the installer container "
             "the wizard cannot see the host UID; the launcher script passes "
             "$(id -u) automatically.",
    )
    dev_group.add_argument(
        "--local-user-name",
        help="Host username to write into LOCAL_USER_NAME. Mirrors --local-user-id.",
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
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate a 7-generation synthetic family tree and (when the stack is up) import it.",
    )
    parser.add_argument(
        "--demo-seed",
        type=int,
        default=42,
        help="RNG seed for the demo tree (default: 42; same seed -> same tree).",
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
            local_user_id=args.local_user_id,
            local_user_name=args.local_user_name,
            force=args.force,
        )
        return _run_with_exit_codes(
            lambda: run_dev(dev_args, stdin=sys.stdin, stdout=sys.stdout)
        )

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
        demo=args.demo,
        demo_seed=args.demo_seed,
        force=args.force,
        no_up=args.no_up,
    )

    return _run_with_exit_codes(
        lambda: run_standalone(flow_args, stdin=sys.stdin, stdout=sys.stdout)
    )


def _run_with_exit_codes(run_fn) -> int:
    """Translate the flow-layer exceptions into the documented exit codes.

    Both standalone and dev branches translate the same three exceptions
    into the same three exit codes; keeping it in one place means Task 7
    can wire the demo-tree --demo branch through the same translator.

    Exit codes:
      2 — PrereqError or PromptError (missing input or hostile environment)
      3 — StackError (docker compose failed mid-flow)
      anything else — flows return verbatim (0 success, 1 user-cancel, 4
        pull/install failure, ...)
    """
    try:
        return run_fn()
    except StackError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 3
    except (PrereqError, PromptError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
