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

from webtrees_installer._io import atomic_write
from webtrees_installer.prereq import check_prerequisites, confirm_overwrite
from webtrees_installer.prompts import PromptError, ask_text, ask_yesno
from webtrees_installer.versions import Catalog, load_catalog


@dataclass(frozen=True)
class DevArgs:
    """All inputs the dev flow needs from the CLI layer."""

    work_dir: Path | None
    interactive: bool

    proxy_mode: str
    dev_domain: str

    app_port: int | None
    pma_port: int | None

    mariadb_host: str
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
    # the wizard default of True); True/False = explicit operator choice
    # that wins over the .env. After collect_dev_inputs() resolves the
    # value this is always concrete True/False before render time.
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
        "mariadb_host": args.mariadb_host,
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
    if args.proxy_mode == "traefik" and not args.dev_domain:
        raise ValueError("traefik proxy_mode requires non-empty dev_domain")
    if args.proxy_mode == "standalone" and (args.app_port is None or args.pma_port is None):
        raise ValueError("standalone proxy_mode requires app_port and pma_port")
    if args.use_external_db and not args.mariadb_host:
        raise ValueError("use_external_db=True requires mariadb_host")
    if not args.host_work_dir:
        raise ValueError("host_work_dir must be a non-empty host-side path")


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

    ``enforce_https`` is tristate: an explicit ``True``/``False`` (operator
    passed a CLI flag) wins over everything; ``None`` (no CLI flag) means
    honour the existing .env's value on a re-render, falling back to the
    wizard's ``True`` default for fresh installs.
    """

    use_traefik = ask_yesno(
        "Is a Traefik reverse proxy available?",
        default=False,
        stdin=stdin, stdout=stdout,
    )
    proxy_mode = "traefik" if use_traefik else "standalone"

    enforce_https = resolve_enforce_https(
        cli_value=enforce_https,
        env_value=existing.get("ENFORCE_HTTPS"),
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
        mariadb_host = ask_text(
            "External MariaDB host (network name or DNS)",
            default=existing.get("MARIADB_HOST", "external-db.local") or "external-db.local",
            stdin=stdin, stdout=stdout,
        )
    else:
        mariadb_host = "db"

    mariadb_root_password = ask_text(
        "MariaDB root password",
        default=existing.get("MARIADB_ROOT_PASSWORD", ""),
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
        stdin=stdin, stdout=stdout,
    )

    return DevArgs(
        work_dir=work_dir,
        interactive=True,
        proxy_mode=proxy_mode,
        dev_domain=dev_domain,
        app_port=app_port,
        pma_port=pma_port,
        mariadb_host=mariadb_host,
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
        stdin=stdin, stdout=stdout,
    ):
        if stdout:
            print("Aborted (existing files preserved).", file=stdout)
        return 1

    # Parse the existing .env once and reuse it for both the tristate
    # resolution and the interactive prompt loop. The resolution runs
    # unconditionally so a None never reaches Jinja, which would otherwise
    # render ENFORCE_HTTPS=FALSE because Python's None is falsy.
    existing = _parse_env(work_dir / ".env")
    args = dataclasses.replace(
        args,
        enforce_https=resolve_enforce_https(
            cli_value=args.enforce_https,
            env_value=existing.get("ENFORCE_HTTPS"),
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
            print(".env written; --no-up requested, skipping compose pull + install.",
                  file=stdout)
        return 0

    pull = _compose(["compose", "pull"], cwd=work_dir)
    if pull.returncode != 0:
        # Errors route to sys.stderr so a `docker run ... | grep error`
        # in CI picks them up, matching how PrereqError / PromptError /
        # StackError get surfaced by the CLI's outer handler.
        print(f"error: docker compose pull failed: {pull.stderr.strip() or pull.stdout.strip()}",
              file=sys.stderr)
        return 4

    install = _compose(
        ["compose", "run", "--rm", "-e", "COMPOSER_AUTH", "buildbox",
         "./scripts/install-application.sh"],
        cwd=work_dir,
    )
    if install.returncode != 0:
        print(f"error: composer install failed: {install.stderr.strip() or install.stdout.strip()}",
              file=sys.stderr)
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


def resolve_enforce_https(
    cli_value: bool | None,
    env_value: str | None,
    *,
    default: bool = True,
) -> bool:
    """Resolve the ENFORCE_HTTPS tristate to a concrete bool.

    Precedence (highest wins):
      1. ``cli_value`` — an explicit operator choice via the CLI flag
         (e.g. ``--no-https`` → False). Anything other than ``None``
         wins outright.
      2. ``env_value`` — the value carried by an existing ``.env`` on
         a re-render. Parsed case-insensitively against ``"TRUE"``.
      3. ``default`` — the wizard's fallback for a fresh install.

    Shared between the standalone and dev flows so the precedence cannot
    drift between the two; without this, three call sites would
    open-code the same `.strip().upper() == "TRUE"` parse.
    """
    if cli_value is not None:
        return cli_value
    if env_value is not None:
        return env_value.strip().upper() == "TRUE"
    return default


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
    bar = "-" * 60
    print(bar, file=stdout)
    print("Webtrees dev environment ready.", file=stdout)
    print(bar, file=stdout)
    if args.proxy_mode == "standalone":
        scheme = "https" if args.enforce_https else "http"
        print(f"Webtrees URL: {scheme}://{args.dev_domain}/", file=stdout)
        print(f"phpMyAdmin URL: http://{args.dev_domain.split(':')[0]}:{args.pma_port}/",
              file=stdout)
    else:
        print(f"Webtrees URL: https://{args.dev_domain}/", file=stdout)

    if args.enforce_https and args.proxy_mode == "standalone":
        print(file=stdout)
        print(
            "NOTE: ENFORCE_HTTPS=TRUE. nginx will redirect plain HTTP to "
            "HTTPS — point a TLS-terminating reverse proxy at the published "
            "port, or re-run with --no-https for a plaintext local install.",
            file=stdout,
        )

    print(file=stdout)
    print("Next: make up", file=stdout)
    print(bar, file=stdout)
