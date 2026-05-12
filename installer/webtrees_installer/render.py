"""Render Jinja2 templates into compose.yaml + .env."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from jinja2 import Environment, PackageLoader, StrictUndefined

from webtrees_installer.versions import Catalog


@dataclass(frozen=True)
class RenderInput:
    """All values the templates need."""

    edition: str
    proxy_mode: str
    app_port: int | None
    domain: str | None
    admin_bootstrap: bool
    admin_user: str | None
    admin_email: str | None
    catalog: Catalog
    generated_at: datetime
    traefik_network: str = "traefik"


_VALID_EDITIONS = {"core", "full"}
_VALID_PROXY_MODES = {"standalone", "traefik"}


def render_files(input_model: RenderInput, *, target_dir: Path) -> None:
    """Write compose.yaml + .env into target_dir based on input_model."""
    _validate(input_model)

    env_jinja = Environment(
        loader=PackageLoader("webtrees_installer", "templates"),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )

    php_entry = input_model.catalog.default_php_entry
    context = {
        "edition": input_model.edition,
        "proxy_mode": input_model.proxy_mode,
        "app_port": input_model.app_port,
        "domain": input_model.domain,
        "admin_bootstrap": input_model.admin_bootstrap,
        "admin_user": input_model.admin_user,
        "admin_email": input_model.admin_email,
        "webtrees_version": php_entry.webtrees,
        "php_version": php_entry.php,
        "nginx_tag": input_model.catalog.nginx_tag,
        "installer_version": input_model.catalog.installer_version,
        "generated_at": input_model.generated_at.isoformat(),
        "traefik_network": input_model.traefik_network,
    }

    compose_template = (
        "compose.standalone.j2"
        if input_model.proxy_mode == "standalone"
        else "compose.traefik.j2"
    )

    compose_text = env_jinja.get_template(compose_template).render(**context)
    env_text = env_jinja.get_template("env.j2").render(**context)

    (target_dir / "compose.yaml").write_text(compose_text)
    (target_dir / ".env").write_text(env_text)


def _validate(input_model: RenderInput) -> None:
    if input_model.edition not in _VALID_EDITIONS:
        raise ValueError(
            f"edition must be one of {_VALID_EDITIONS}, got {input_model.edition!r}"
        )
    if input_model.proxy_mode not in _VALID_PROXY_MODES:
        raise ValueError(
            f"proxy_mode must be one of {_VALID_PROXY_MODES}, "
            f"got {input_model.proxy_mode!r}"
        )
    if input_model.proxy_mode == "standalone" and input_model.app_port is None:
        raise ValueError("standalone proxy_mode requires app_port")
    if input_model.proxy_mode == "traefik" and not input_model.domain:
        raise ValueError("traefik proxy_mode requires domain")
    if input_model.admin_bootstrap and not input_model.admin_user:
        raise ValueError("admin_bootstrap=True requires admin_user")
    if input_model.admin_bootstrap and not input_model.admin_email:
        raise ValueError("admin_bootstrap=True requires admin_email")
