"""Dev-flow .env renderer.

The dev flow does NOT render a fresh compose.yaml — the developer stays
on the repo's compose.yaml + overlays. The wizard only emits a `.env`
that selects the right COMPOSE_FILE chain and carries DB / user / port
values so `make up` succeeds without further editing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from jinja2 import Environment, PackageLoader, StrictUndefined

from webtrees_installer.versions import Catalog


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

    local_user_id: int
    local_user_name: str

    force: bool


def build_compose_chain(*, proxy_mode: str, use_external_db: bool) -> str:
    """Return the COMPOSE_FILE colon-chain for the chosen dev flavour."""
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
    }

    env_jinja = Environment(
        loader=PackageLoader("webtrees_installer", "templates"),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    rendered = env_jinja.get_template("env.dev.j2").render(**context)

    target_dir.mkdir(parents=True, exist_ok=True)
    (target_dir / ".env").write_text(rendered)


def _validate(args: DevArgs) -> None:
    if args.proxy_mode not in {"standalone", "traefik"}:
        raise ValueError(
            f"proxy_mode must be 'standalone' or 'traefik', got {args.proxy_mode!r}"
        )
    if args.proxy_mode == "traefik" and not args.dev_domain:
        raise ValueError("traefik proxy_mode requires non-empty dev_domain")
    if args.proxy_mode == "standalone" and (args.app_port is None or args.pma_port is None):
        raise ValueError("standalone proxy_mode requires app_port and pma_port")
    if args.use_external_db and not args.mariadb_host:
        raise ValueError("use_external_db=True requires mariadb_host")
