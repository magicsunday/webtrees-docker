"""Dev-flow .env renderer.

The dev flow does NOT render a fresh compose.yaml — the developer stays
on the repo's compose.yaml + overlays. The wizard only emits a `.env`
that selects the right COMPOSE_FILE chain and carries DB / user / port
values so `make up` succeeds without further editing.
"""

from __future__ import annotations

import dataclasses
import os
import socket
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import IO

from jinja2 import Environment, PackageLoader, StrictUndefined

from webtrees_installer._banner import (
    print_standalone_enforce_https_warning,
    print_standalone_http_security_note,
    print_standalone_http_url_lan_only,
    print_what_next_section,
)
from webtrees_installer._byod_invariants import (
    FIELD_NAMES,
    external_db_host_error,
)
from webtrees_installer._cli_resolve import resolve_enforce_https
from webtrees_installer._io import atomic_write
from webtrees_installer._term import Term
from webtrees_installer.prereq import check_prerequisites, confirm_overwrite
from webtrees_installer.prompts import PromptError, ask_text, ask_yesno
from webtrees_installer.versions import Catalog, load_catalog


def _host_without_port(value: str) -> str:
    """Return the host part of a ``host:port`` / ``[ipv6]:port`` / bare-host value.

    The phpMyAdmin banner re-derives the host from the formatted
    ``dev_domain``. A naive ``split(':')[0]`` yields ``[fd00`` for an
    IPv6 literal and mangles a ``scheme://host`` form; this strips only a
    trailing ``:port`` and is bracket-aware for IPv6.
    """
    if value.startswith("["):
        end = value.find("]")
        if end != -1:
            return value[: end + 1]
    if value.count(":") == 1:
        return value.rsplit(":", 1)[0]
    return value


@dataclass(frozen=True)
class DevArgs:
    """All inputs the dev flow needs from the CLI layer."""

    work_dir: Path | None
    interactive: bool

    # Persisted only. The dev stack builds webtrees from the module-dev
    # source, so the running container ignores the image edition — but the
    # operator's standalone edition choice (core vs full) must survive a
    # `./switch dev` → `./switch standalone` round-trip, which overwrites
    # the standalone .env with the dev one. Carrying EDITION through the
    # dev .env is the only durable place to keep it, so `switch` can read
    # it back instead of hard-coding `--edition full`.
    edition: str

    proxy_mode: str
    dev_domain: str

    app_port: int | None
    pma_port: int | None

    external_db_host: str
    mariadb_database: str
    mariadb_user: str
    mariadb_password: str
    mariadb_root_password: str
    use_existing_db: bool
    use_external_db: bool

    # Sentinels: the CLI builds DevArgs before host detection runs, so
    # both fields default to None and run_dev fills them in via
    # _detect_host_info(). The interactive collect_dev_inputs path
    # supplies real values from HostInfo directly.
    local_user_id: int | None
    local_user_name: str | None

    # Host-side cwd that compose bind-mounts must resolve against. Inside
    # the installer container ${PWD} is /work, which does not exist on
    # the host docker daemon, so compose.development.yaml's device-paths
    # break unless the wizard writes the real host path into .env.
    # None → run_dev() falls back to WORK_DIR env var or os.getcwd().
    host_work_dir: str | None

    # Tristate, mirrors admin_bootstrap in flow.py: None = operator
    # didn't pass --no-https on the CLI (use .env value if present, else
    # the proxy_mode-keyed smart default — standalone FALSE / traefik
    # TRUE, see _cli_resolve.resolve_enforce_https); True/False =
    # explicit operator choice that wins over the .env. After
    # collect_dev_inputs() resolves the value this is always concrete
    # True/False before render time.
    enforce_https: bool | None

    force: bool
    no_up: bool


@dataclass(frozen=True)
class HostInfo:
    """Host-side facts the dev flow needs (UID, username, server IP)."""

    uid: int
    username: str
    primary_ip: str
    work_dir: str


def build_compose_chain(*, proxy_mode: str, use_external_db: bool) -> str:
    """Return the COMPOSE_FILE colon-chain for the chosen dev flavour.

    Single source of truth for the proxy-mode validation: the chain
    assembler raises ValueError on an unknown mode and the caller
    (``render_dev_env`` via ``_validate``) leans on that instead of
    re-checking the same condition.
    """
    chain = ["compose.yaml", "compose.pma.yaml", "compose.development.yaml"]
    if proxy_mode == "standalone":
        chain.append("compose.publish.yaml")
    elif proxy_mode == "traefik":
        chain.append("compose.traefik.yaml")
    else:
        raise ValueError(f"proxy_mode must be 'standalone' or 'traefik', got {proxy_mode!r}")
    if use_external_db:
        chain.append("compose.external.yaml")
    return ":".join(chain)


def render_dev_env(
    args: DevArgs,
    *,
    catalog: Catalog,
    target_dir: Path,
    generated_at: datetime,
) -> None:
    """Render env.dev.j2 into target_dir/.env."""
    _validate(args)

    php_entry = catalog.default_php_entry
    context = {
        "installer_version": catalog.installer_version,
        "generated_at": generated_at.isoformat(),
        "edition": args.edition,
        "compose_file_chain": build_compose_chain(
            proxy_mode=args.proxy_mode, use_external_db=args.use_external_db,
        ),
        "proxy_mode": args.proxy_mode,
        "dev_domain": args.dev_domain,
        "app_port": args.app_port,
        "pma_port": args.pma_port,
        "php_version": php_entry.php,
        "webtrees_version": php_entry.webtrees,
        "nginx_tag": catalog.nginx_tag,
        # Template key stays MARIADB_HOST (the env var webtrees reads);
        # only the DevArgs field was renamed to external_db_host so the
        # external-db invariant shares vocabulary with flow / render.
        "mariadb_host": args.external_db_host,
        "mariadb_database": args.mariadb_database,
        "mariadb_user": args.mariadb_user,
        "mariadb_password": args.mariadb_password,
        "mariadb_root_password": args.mariadb_root_password,
        "use_existing_db": args.use_existing_db,
        "local_user_id": args.local_user_id,
        "local_user_name": args.local_user_name,
        "work_dir": args.host_work_dir or "",
        "enforce_https": args.enforce_https,
    }

    env_jinja = Environment(
        loader=PackageLoader("webtrees_installer", "templates"),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )
    rendered = env_jinja.get_template("env.dev.j2").render(**context)

    if target_dir.exists() and not target_dir.is_dir():
        raise NotADirectoryError(
            f"target_dir {target_dir} exists but is not a directory"
        )
    target_dir.mkdir(parents=True, exist_ok=True)
    atomic_write(target_dir / ".env", rendered)


def _validate(args: DevArgs) -> None:
    # proxy_mode is validated by build_compose_chain when render_dev_env
    # invokes it; calling it here once keeps the check authoritative
    # without duplicating the message string.
    build_compose_chain(proxy_mode=args.proxy_mode, use_external_db=args.use_external_db)
    # These four are operator-supplied-input failures: a non-interactive
    # dev run that omits a required flag must exit 2 (the documented
    # missing-input path), not escape _run_with_exit_codes as an uncaught
    # ValueError → traceback + exit 1. PromptError is the type the CLI
    # exit-code translator maps to 2, matching the legacy-.env APP_PORT
    # path already covered by test_dev_flow.
    if args.proxy_mode == "traefik" and not args.dev_domain:
        raise PromptError("traefik proxy_mode requires non-empty dev_domain")
    if args.proxy_mode == "standalone" and (args.app_port is None or args.pma_port is None):
        raise PromptError("standalone proxy_mode requires app_port and pma_port")
    host_error = external_db_host_error(
        use_external_db=args.use_external_db,
        host=args.external_db_host,
        naming=FIELD_NAMES,
    )
    if host_error is not None:
        raise PromptError(host_error)
    if not args.host_work_dir:
        raise PromptError("host_work_dir must be a non-empty host-side path")


def collect_dev_inputs(
    *,
    work_dir: Path,
    force: bool,
    existing: dict[str, str],
    host_info: HostInfo,
    no_up: bool = False,
    enforce_https: bool | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> DevArgs:
    """Drive the dev-flow prompts. `existing` carries values from a previous .env.

    The caller threads ``force`` and ``no_up`` through unchanged so a user
    who passes ``--no-up`` on the command line keeps that behaviour even
    when the wizard runs the interactive prompt loop.

    ``enforce_https`` is tristate: an explicit ``True``/``False``
    (operator passed a CLI flag) wins over everything; ``None`` (no
    CLI flag) means honour the existing .env's value on a re-render,
    falling back to the proxy_mode-keyed smart default for fresh
    installs (standalone FALSE / traefik TRUE — see
    :func:`webtrees_installer._cli_resolve.resolve_enforce_https`).
    """

    use_traefik = ask_yesno(
        "Is a Traefik reverse proxy available?",
        default=False,
        stdin=stdin, stdout=stdout,
    )
    proxy_mode = "traefik" if use_traefik else "standalone"

    # See resolve_enforce_https' docstring for the proxy_mode-keyed
    # smart default (standalone → FALSE / traefik → TRUE). The
    # prompt-resolved `proxy_mode` local feeds it so the operator's
    # `use_traefik` choice drives the default.
    enforce_https = resolve_enforce_https(
        cli_value=enforce_https,
        env_value=existing.get("ENFORCE_HTTPS"),
        proxy_mode=proxy_mode,
    )

    app_port: int | None = None
    pma_port: int | None = None
    if proxy_mode == "standalone":
        app_port_default = _parse_port_default(existing.get("APP_PORT"), 50010, "APP_PORT")
        pma_port_default = _parse_port_default(existing.get("PMA_PORT"), 50011, "PMA_PORT")
        app_port = _ask_port(
            "Host port for Webtrees (maps to container 80)",
            default=app_port_default,
            stdin=stdin, stdout=stdout,
        )
        pma_port = _ask_port(
            "Host port for phpMyAdmin (maps to container 80)",
            default=pma_port_default,
            stdin=stdin, stdout=stdout,
        )
        default_domain = existing.get("DEV_DOMAIN") or f"{host_info.primary_ip}:{app_port}"
    else:
        default_domain = existing.get("DEV_DOMAIN") or "webtrees.example.org"

    dev_domain = ask_text(
        "Domain under which the dev system should be reachable",
        default=default_domain,
        stdin=stdin, stdout=stdout,
    )

    use_existing_db = ask_yesno(
        "Use an existing, already-initialised database?",
        default=False,
        stdin=stdin, stdout=stdout,
    )
    use_external_db = ask_yesno(
        "Use an external database?",
        default=False,
        stdin=stdin, stdout=stdout,
    )

    if use_external_db:
        external_db_host = ask_text(
            "External MariaDB host (network name or DNS)",
            default=existing.get("MARIADB_HOST", "external-db.local") or "external-db.local",
            stdin=stdin, stdout=stdout,
        )
    else:
        external_db_host = "db"

    mariadb_root_password = ask_text(
        "MariaDB root password",
        default=existing.get("MARIADB_ROOT_PASSWORD", ""),
        secret=True,
        stdin=stdin, stdout=stdout,
    )
    mariadb_database = ask_text(
        "MariaDB database name",
        default=existing.get("MARIADB_DATABASE", "webtrees") or "webtrees",
        stdin=stdin, stdout=stdout,
    )
    mariadb_user = ask_text(
        "MariaDB username",
        default=existing.get("MARIADB_USER", "webtrees") or "webtrees",
        stdin=stdin, stdout=stdout,
    )
    mariadb_password = ask_text(
        "MariaDB user password",
        default=existing.get("MARIADB_PASSWORD", ""),
        secret=True,
        stdin=stdin, stdout=stdout,
    )

    return DevArgs(
        work_dir=work_dir,
        interactive=True,
        # Not prompted in dev mode; carried forward from the prior .env so
        # a later `./switch standalone` restores the operator's edition.
        edition=existing.get("EDITION") or "full",
        proxy_mode=proxy_mode,
        dev_domain=dev_domain,
        app_port=app_port,
        pma_port=pma_port,
        external_db_host=external_db_host,
        mariadb_database=mariadb_database,
        mariadb_user=mariadb_user,
        mariadb_password=mariadb_password,
        mariadb_root_password=mariadb_root_password,
        use_existing_db=use_existing_db,
        use_external_db=use_external_db,
        local_user_id=host_info.uid,
        local_user_name=host_info.username,
        host_work_dir=host_info.work_dir,
        enforce_https=enforce_https,
        force=force,
        no_up=no_up,
    )


def _parse_port_default(raw: str | None, fallback: int, label: str) -> int:
    """Parse a port string from an existing .env, falling back if absent or bad."""
    if raw is None or raw == "":
        return fallback
    try:
        return int(raw)
    except ValueError as exc:
        raise PromptError(
            f"{label} in existing .env is not numeric: {raw!r}"
        ) from exc


def _ask_port(
    question: str,
    *,
    default: int,
    stdin: IO[str] | None,
    stdout: IO[str] | None,
) -> int:
    """Ask the user for a port; surface a PromptError on non-numeric input."""
    reply = ask_text(
        question,
        default=str(default),
        stdin=stdin, stdout=stdout,
    )
    try:
        return int(reply)
    except ValueError as exc:
        raise PromptError(
            f"{question}: not a number: {reply!r}"
        ) from exc


# Test-patch seam: tests can patch
# ``webtrees_installer.dev_flow._resolve_manifest_dir``. The implementation
# lives in webtrees_installer.versions so a future bake-location change is
# a one-file edit shared with flow.py. To override the bake location
# itself, patch ``webtrees_installer.versions.DEFAULT_MANIFEST_DIR``
# directly — a local alias here would silently no-op because the
# resolver reads versions.DEFAULT_MANIFEST_DIR.
from webtrees_installer.versions import (  # noqa: E402
    resolve_manifest_dir as _resolve_manifest_dir,
)


def run_dev(
    args: DevArgs,
    *,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> int:
    """Drive the dev-flow end to end. Returns process exit code."""
    work_dir = args.work_dir or Path("/work")

    # Detect once and reuse both for sentinel-filling and for the
    # interactive prompt loop below. The detector reads WORK_DIR from
    # the env (set by the launcher) so the host's cwd survives the
    # docker-in-docker hop into the installer container.
    if (
        args.local_user_id is None
        or args.local_user_name is None
        or not args.host_work_dir
    ):
        host_info = _detect_host_info()
        args = dataclasses.replace(
            args,
            local_user_id=args.local_user_id if args.local_user_id is not None else host_info.uid,
            local_user_name=args.local_user_name or host_info.username,
            host_work_dir=args.host_work_dir or host_info.work_dir,
        )

    check_prerequisites(work_dir=work_dir)

    if not confirm_overwrite(
        work_dir=work_dir,
        interactive=args.interactive,
        force=args.force,
        # Dev mode only writes .env; it stays on the repo's committed
        # compose.yaml, so the default (compose.yaml, .env) guard would
        # falsely flag the always-present repo compose.yaml as a conflict.
        names=(".env",),
        stdin=stdin, stdout=stdout,
    ):
        if stdout:
            print(
                Term.for_stream(stdout).warning("Aborted (existing files preserved)."),
                file=stdout,
            )
        return 1

    # Parse the existing .env once and reuse it for both the tristate
    # resolution and the interactive prompt loop. For non-interactive
    # runs, normalise now so a None never reaches Jinja (Python's None
    # would otherwise render as ENFORCE_HTTPS=FALSE because None is
    # falsy). For interactive runs, defer to collect_dev_inputs which
    # sees the PROMPT-RESOLVED `proxy_mode` and applies the smart
    # default correctly — pre-resolving here would lock in a default
    # derived from `args.proxy_mode` (the CLI placeholder, typically
    # "standalone"), and a subsequent operator choice of "Traefik" at
    # the use_traefik prompt would land with the wrong default.
    existing = _parse_env(work_dir / ".env")
    if not args.interactive:
        args = dataclasses.replace(
            args,
            enforce_https=resolve_enforce_https(
                cli_value=args.enforce_https,
                env_value=existing.get("ENFORCE_HTTPS"),
                proxy_mode=args.proxy_mode,
            ),
        )

    if args.interactive:
        host_info = _detect_host_info()
        args = collect_dev_inputs(
            work_dir=work_dir, force=args.force,
            existing=existing,
            host_info=host_info,
            no_up=args.no_up,
            enforce_https=args.enforce_https,
            stdin=stdin, stdout=stdout,
        )

    catalog = load_catalog(_resolve_manifest_dir())
    render_dev_env(
        args, catalog=catalog, target_dir=work_dir,
        generated_at=datetime.now(tz=timezone.utc),
    )

    for relative in ("persistent/database", "persistent/media", "app"):
        (work_dir / relative).mkdir(parents=True, exist_ok=True)

    # --no-up: write files + create persistent dirs, then stop. Skips
    # the compose-pull + composer-install pair so smoke tests can verify
    # the .env contract without paying for a 5-10 min bring-up.
    if args.no_up:
        if stdout:
            term = Term.for_stream(stdout)
            print(
                f"{term.info('•')} .env written; --no-up requested, skipping compose pull + install.",
                file=stdout,
            )
        return 0

    err_term = Term.for_stream(sys.stderr)
    # `--ignore-buildable` skips services with a `build:` block.
    # The dev compose has `build:` for `buildbox`, `buildbox-root`,
    # and `phpfpm` (locally-built dev images that don't exist in any
    # registry — see issue #132); pulling them would error with
    # `manifest unknown` and abort the wizard. Pullable images
    # (mariadb, browser, etc.) still fetch their latest tags.
    # Requires Compose v2.22+ (already required by check_prerequisites).
    pull = _compose(["compose", "pull", "--ignore-buildable"], cwd=work_dir)
    if pull.returncode != 0:
        # Errors route to sys.stderr so a `docker run ... | grep error`
        # in CI picks them up, matching how PrereqError / PromptError /
        # StackError get surfaced by the CLI's outer handler.
        print(
            f"{err_term.error('error:')} docker compose pull failed: "
            f"{pull.stderr.strip() or pull.stdout.strip()}",
            file=sys.stderr,
        )
        return 4

    # Build the locally-buildable dev images explicitly before `compose
    # run` invokes one of them. `compose run` would build on-demand but
    # surfaces the build output as part of the run step, hiding image-
    # build failures behind the install-script output (issue #132).
    build = _compose(["compose", "build"], cwd=work_dir)
    if build.returncode != 0:
        print(
            f"{err_term.error('error:')} docker compose build failed: "
            f"{build.stderr.strip() or build.stdout.strip()}",
            file=sys.stderr,
        )
        return 4

    install = _compose(
        ["compose", "run", "--rm", "-e", "COMPOSER_AUTH", "buildbox",
         "./scripts/build/install-application.sh"],
        cwd=work_dir,
    )
    if install.returncode != 0:
        print(
            f"{err_term.error('error:')} composer install failed: "
            f"{install.stderr.strip() or install.stdout.strip()}",
            file=sys.stderr,
        )
        return 4

    if stdout:
        _print_dev_banner(stdout=stdout, args=args)
    return 0


def _detect_host_info() -> HostInfo:
    """Read UID, username, primary IPv4 and host work-dir for prompt defaults."""
    try:
        uid = os.geteuid()
    except AttributeError:
        uid = 0
    username = os.environ.get("USER") or os.environ.get("LOGNAME") or "developer"
    # WORK_DIR is set by the launcher script from the host shell's $PWD;
    # falling back to os.getcwd() keeps direct-host invocations (running
    # the wizard outside the installer container) working.
    work_dir = os.environ.get("WORK_DIR") or os.getcwd()
    primary_ip = "127.0.0.1"
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(("1.1.1.1", 80))
            primary_ip = sock.getsockname()[0]
        finally:
            sock.close()
    except OSError:
        pass
    return HostInfo(uid=uid, username=username, primary_ip=primary_ip, work_dir=work_dir)


def _parse_env(path: Path) -> dict[str, str]:
    """Best-effort .env reader for prompt defaults."""
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


# Test-patch seam kept as a thin alias so existing test patches on
# ``webtrees_installer.dev_flow._compose`` keep working. The shared
# helper in ``webtrees_installer._docker`` is the single implementation.
from webtrees_installer._docker import run_docker as _compose  # noqa: E402


def _print_dev_banner(*, stdout: IO[str], args: DevArgs) -> None:
    """Print the post-install summary block with URLs and next steps."""
    term = Term.for_stream(stdout)
    bar = "-" * 60
    print(term.bold(bar), file=stdout)
    print(term.bold("Webtrees dev environment ready."), file=stdout)
    print(term.bold(bar), file=stdout)
    if args.proxy_mode == "standalone":
        if args.enforce_https:
            # See _banner.print_standalone_enforce_https_warning for
            # the full rationale (SSL_ERROR_RX_RECORD_TOO_LONG trap).
            # Both flow.py + dev_flow.py share this snippet so the
            # operator-facing text stays consistent.
            print_standalone_enforce_https_warning(
                stdout=stdout,
                term=term,
                redirect_target=args.dev_domain,
                rerun_verb="dev wizard",
            )
        else:
            print(f"{term.info('•')} Webtrees URL: http://{args.dev_domain}/", file=stdout)
            # Issue #138 parity with production banner: surface the LAN
            # URL when HOST_LAN_IP was detected so a developer SSHing
            # into a remote dev VM (or browsing from another machine on
            # the same network) gets a URL that resolves without an
            # /etc/hosts edit. Only renders when standalone+no-HTTPS
            # because dev_domain is operator-chosen and frequently a
            # /etc/hosts-only hostname.
            if args.app_port is not None:
                print_standalone_http_url_lan_only(
                    stdout=stdout,
                    term=term,
                    app_port=args.app_port,
                    host_lan_ip=os.environ.get("HOST_LAN_IP", "").strip() or None,
                )
            # Symmetric advisory mirrors the production banner: surface
            # the cleartext-on-LAN trade-off so a developer running on a
            # shared dev VM / Wi-Fi gets it explicitly.
            print_standalone_http_security_note(stdout=stdout, term=term)
        print(
            f"{term.info('•')} phpMyAdmin URL: http://{_host_without_port(args.dev_domain)}:{args.pma_port}/",
            file=stdout,
        )
    else:
        print(f"{term.info('•')} Webtrees URL: https://{args.dev_domain}/", file=stdout)

    print(file=stdout)
    print(f"{term.info('•')} Next: make up", file=stdout)

    # Re-entry guide — same operator-friendliness rationale as the
    # production banner (issue #119): the dev wizard can also be
    # re-run / switched via the curl-pipe-bash launchers even though
    # dev-mode users normally have the repo checkout at hand.
    print_what_next_section(stdout=stdout, term=term)

    print(term.bold(bar), file=stdout)
