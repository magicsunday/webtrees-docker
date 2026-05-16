"""Command-line entry point for webtrees-installer."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Sequence
from pathlib import Path

from webtrees_installer import __version__
from webtrees_installer._term import Term
from webtrees_installer.flow import StandaloneArgs, run_standalone
from webtrees_installer.prereq import PrereqError
from webtrees_installer.prompts import TRAEFIK_TLS_INCOMPAT_REASON, PromptError
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
        "--traefik-network",
        dest="traefik_network",
        default="traefik",
        help="External Docker network name the rendered stack joins in "
             "Traefik proxy mode. Both the `traefik.docker.network` "
             "label and the `networks:` section receive this value. "
             "Default `traefik`; override when your Traefik runs on a "
             "differently-named network (e.g. `proxy`, `edge-net`).",
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
    parser.add_argument(
        "--use-external-db",
        action="store_true",
        help="Skip the bundled `db` service and connect phpfpm directly to an "
             "operator-supplied MariaDB / MySQL host (see --external-db-* "
             "flags below). Standalone mode: phpfpm reads MARIADB_HOST / "
             "MARIADB_USER / MARIADB_PASSWORD_FILE / MARIADB_DATABASE from "
             "the rendered .env. Dev mode: appends compose.external.yaml to "
             "the COMPOSE_FILE chain. The wizard probes TCP reachability "
             "before render and refuses fast on DNS / firewall / refused "
             "errors. See docs/byod.md.",
    )
    parser.add_argument(
        "--external-db-host",
        help="External MariaDB host (DNS name, container name, or IP). "
             "Required with --use-external-db in both standalone and dev modes.",
    )
    parser.add_argument(
        "--external-db-port",
        type=int,
        default=3306,
        help="External MariaDB port (default 3306). Standalone mode only.",
    )
    parser.add_argument(
        "--external-db-name",
        default="webtrees",
        help="External MariaDB database name (default 'webtrees'). "
             "Must exist on the external server before install. "
             "Standalone mode only.",
    )
    parser.add_argument(
        "--external-db-user",
        default="webtrees",
        help="External MariaDB application user (default 'webtrees'). "
             "Must have CREATE / DROP / SELECT / INSERT / UPDATE / DELETE / "
             "ALTER / INDEX on --external-db-name. Standalone mode only.",
    )
    parser.add_argument(
        "--external-db-password-file",
        help="Host path to a file containing the --external-db-user's "
             "password. Bind-mounted read-only into phpfpm at "
             "/secrets/external_db_password. Recommended mode 0400; "
             "must be readable by the php-fpm container's runtime user. "
             "Required with --use-external-db in standalone mode.",
    )
    parser.add_argument(
        "--db-data-path",
        help="Host path bind-mounted as MariaDB's /var/lib/mysql, replacing "
             "the bundled `database` named volume. Useful when you have "
             "existing webtrees data on disk, or when you want the DB on a "
             "specific filesystem. Path must exist and be a directory; on "
             "first start mariadb expects it empty (or pre-populated from a "
             "compatible-version dump). Incompatible with --use-external-db "
             "(no `db` service to mount into).",
    )
    parser.add_argument(
        "--media-path",
        help="Host path bind-mounted as webtrees' data/media directory, "
             "replacing the bundled `media` named volume. Path must exist "
             "and be a directory; the php-fpm container's runtime user "
             "needs read+write — verify the image's www-data uid with "
             "`docker run --rm <php-image> id www-data` if you hit "
             "permission errors.",
    )
    parser.add_argument(
        "--reuse-volumes",
        dest="reuse_volumes_project",
        help="Pin the rendered stack's `database` + `media` volumes to an "
             "existing compose project's `<project>_database` + "
             "`<project>_media` named volumes via `external: true`. "
             "Useful when re-installing into a sibling directory while "
             "preserving an existing tree. The wizard verifies both "
             "volumes exist via `docker volume inspect` before render. "
             "Mutually exclusive with --use-external-db / --db-data-path / "
             "--media-path — pick exactly one BYOD pattern.",
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
    dev_group.add_argument(
        "--work-dir-host",
        dest="host_work_dir",
        help="Host-side work directory written into WORK_DIR= in the rendered "
             ".env. compose.development.yaml's bind-mount paths read this "
             "variable so they resolve on the host docker daemon. Inside the "
             "installer container the launcher exports the host $PWD via the "
             "WORK_DIR env var; this flag is the explicit override.",
    )
    parser.add_argument(
        "--admin-user",
        help="Username for the headless admin-bootstrap (default: 'admin' with "
             "an autogenerated random password printed in the install banner).",
    )
    parser.add_argument(
        "--admin-email",
        help="Email for the headless admin-bootstrap "
             "(default: admin@example.org).",
    )
    parser.add_argument(
        "--no-admin",
        action="store_true",
        help="Advanced: skip the admin-bootstrap entirely. The stack then "
             "starts in webtrees' upstream setup wizard, which asks the "
             "operator for DB credentials they would need to read from the "
             "secrets/ folder by hand. Default mode (no flag) is more "
             "convenient: an admin user is created automatically and the "
             "credentials are printed at the end of the install.",
    )
    parser.add_argument(
        "--no-up",
        action="store_true",
        help="Write files but do not run `docker compose up -d`.",
    )
    parser.add_argument(
        "--no-https",
        action="store_true",
        help="Standalone proxy mode only. Opt out of HTTPS enforcement "
             "(ENFORCE_HTTPS=FALSE). The default is ENFORCE_HTTPS=TRUE; "
             "use this flag for local-only installs without TLS termination, "
             "or for setups where a separate upstream proxy (not the bundled "
             "Traefik template) handles HTTP-only forwarding. Rejected with "
             "--proxy traefik because the rendered Traefik router still "
             "terminates TLS at the edge — see docs/customizing.md.",
    )
    parser.add_argument(
        "--pretty-urls",
        action="store_true",
        help="Standalone mode only. Enable webtrees pretty URLs "
             "(rewrite_urls=1 in config.ini.php) so tree pages serve as "
             "/tree/.../individual/... rather than ?route=... query strings. "
             "Off by default. Dev mode honours WEBTREES_REWRITE_URLS in .env "
             "directly — edit there instead.",
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

    return _run_with_exit_codes(lambda: _dispatch(args))


def _dispatch(args: argparse.Namespace) -> int:
    """Run mode-compatibility checks and hand off to the chosen flow.

    Called inside ``_run_with_exit_codes`` so any ``PromptError`` /
    ``PrereqError`` / ``StackError`` raised here (or by the flows below)
    funnels through the single exit-code translator.
    """
    _validate_mode_compatibility(args)

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
            # --work-dir-host overrides WORK_DIR env; None lets run_dev's
            # _detect_host_info() pick up the env var (or fall back to
            # os.getcwd() for direct-host invocations).
            host_work_dir=args.host_work_dir,
            # Tristate: --no-https → False (explicit opt-out); absence →
            # None (let collect_dev_inputs honour the existing .env or
            # fall through to the wizard's TRUE default).
            enforce_https=False if args.no_https else None,
            force=args.force,
            no_up=args.no_up,
        )
        return run_dev(dev_args, stdin=sys.stdin, stdout=sys.stdout)

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
        traefik_network=args.traefik_network,
        admin_bootstrap=admin_bootstrap,
        admin_user=args.admin_user,
        admin_email=args.admin_email,
        demo=args.demo,
        demo_seed=args.demo_seed,
        # Tristate: --no-https → False; absence → None (let the standalone
        # flow apply the wizard's TRUE default).
        enforce_https=False if args.no_https else None,
        pretty_urls=args.pretty_urls,
        force=args.force,
        no_up=args.no_up,
        use_external_db=args.use_external_db,
        external_db_host=args.external_db_host,
        external_db_port=args.external_db_port,
        external_db_name=args.external_db_name,
        external_db_user=args.external_db_user,
        external_db_password_file=args.external_db_password_file,
        db_data_path=args.db_data_path,
        media_path=args.media_path,
        reuse_volumes_project=args.reuse_volumes_project,
    )

    return run_standalone(flow_args, stdin=sys.stdin, stdout=sys.stdout)


def _validate_mode_compatibility(args: argparse.Namespace) -> None:
    """Raise PromptError when an argument combination is invalid for args.mode.

    Cross-flag interactions are checked here, before any flow runs, so the
    operator sees the same ``error: ...`` prefix and exit-code-2 path the
    flows themselves use.

    Today's policy is selective, not symmetric. Most standalone-only flags
    (``--demo``, ``--demo-seed``, ``--admin-user``, ``--admin-email``,
    ``--no-admin``, ``--edition``, ``--domain``) are silently dropped when
    ``--mode dev`` is passed: the dev flow does not read them and no
    operator-facing harm follows from ignoring them. Same direction the
    other way — dev-only flags (``--pma-port``, ``--dev-domain``,
    ``--mariadb-*``, ``--use-existing-db``, ``--local-user-*``,
    ``--work-dir-host``) pass through silently in standalone mode
    because the dev surface is a superset. ``--use-external-db`` and
    its ``--external-db-*`` companions are first-class in both modes
    (see GH-41 BYOD).

    ``--pretty-urls`` is the one explicit exception: a fresh install
    rendered with ``--mode dev --pretty-urls`` would silently ship a stack
    with ``WEBTREES_REWRITE_URLS=0`` (env.dev.j2 hard-codes it) — the
    operator's intent vanishes with no trace. Hard-rejecting at the CLI
    layer surfaces the mismatch and points at the .env knob the dev flow
    actually reads.
    """
    # TODO: lift into a flag→message registry when this if-chain grows
    # another branch; revisit argparse subparsers if dev/standalone flag
    # sets diverge enough that the flat parser stops carrying its weight.
    if args.mode == "dev" and args.pretty_urls:
        raise PromptError(
            "--pretty-urls is standalone-only. In dev mode set "
            "WEBTREES_REWRITE_URLS=1 in .env (scripts/configuration "
            "writes it into config.ini.php on install)."
        )
    if (
        args.mode == "standalone"
        and args.proxy_mode == "traefik"
        and args.no_https
    ):
        raise PromptError(
            "--no-https is incompatible with --proxy traefik: "
            f"{TRAEFIK_TLS_INCOMPAT_REASON}. "
            "Drop --no-https for Traefik, or switch to --proxy standalone."
        )


def _run_with_exit_codes(run_fn: Callable[[], int]) -> int:
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
    err_term = Term.for_stream(sys.stderr)
    try:
        return run_fn()
    except StackError as exc:
        print(f"{err_term.error('error:')} {exc}", file=sys.stderr)
        return 3
    except (PrereqError, PromptError) as exc:
        print(f"{err_term.error('error:')} {exc}", file=sys.stderr)
        return 2
