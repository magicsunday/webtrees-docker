"""Render Jinja2 templates into compose.yaml + .env."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from jinja2 import Environment, PackageLoader, StrictUndefined

from webtrees_installer._alpine import ALPINE_BASE_IMAGE
from webtrees_installer._io import atomic_write
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
    enforce_https: bool = True
    pretty_urls: bool = False

    # #41 BYOD external-db: when True the rendered compose drops the
    # bundled `db:` service and points phpfpm at the operator-supplied
    # host. The four `external_db_*` strings carry the connection details
    # the wizard wrote to .env; `external_db_password_file` is the host
    # path bind-mounted into phpfpm at /secrets/external_db_password.
    # Defaults below keep render_files() backward-compatible for the
    # local-db path (all five values unused when use_external_db=False).
    use_external_db: bool = False
    external_db_host: str = ""
    external_db_port: int = 3306
    external_db_name: str = "webtrees"
    external_db_user: str = "webtrees"
    external_db_password_file: str = ""


_VALID_EDITIONS = {"core", "full"}
_VALID_PROXY_MODES = {"standalone", "traefik"}


def render_files(*, input_model: RenderInput, target_dir: Path) -> None:
    """Write compose.yaml + .env into target_dir based on input_model.

    The renderer prepares both texts first, then commits each via a
    temp-file + ``Path.replace`` swap so an interrupted run cannot leave
    the user with a half-written compose.yaml while the .env still points
    at the previous run's image tags. ``target_dir`` is created if it
    does not exist; both files land at mode 0644.
    """
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
        "enforce_https": input_model.enforce_https,
        "pretty_urls": input_model.pretty_urls,
        "use_external_db": input_model.use_external_db,
        "external_db_host": input_model.external_db_host,
        "external_db_port": input_model.external_db_port,
        "external_db_name": input_model.external_db_name,
        "external_db_user": input_model.external_db_user,
        "external_db_password_file": input_model.external_db_password_file,
        # Pin lives in webtrees_installer._alpine and is consumed verbatim;
        # the templates carry no fallback, so a renaming bug here trips
        # Jinja's StrictUndefined immediately.
        "alpine_image": ALPINE_BASE_IMAGE,
    }

    compose_template = (
        "compose.standalone.j2"
        if input_model.proxy_mode == "standalone"
        else "compose.traefik.j2"
    )

    compose_text = env_jinja.get_template(compose_template).render(**context)
    env_text = env_jinja.get_template("env.j2").render(**context)
    makefile_text = env_jinja.get_template("Makefile.j2").render(**context)

    if target_dir.exists() and not target_dir.is_dir():
        raise NotADirectoryError(
            f"target_dir {target_dir} exists but is not a directory"
        )
    target_dir.mkdir(parents=True, exist_ok=True)
    atomic_write(target_dir / "compose.yaml", compose_text)
    atomic_write(target_dir / ".env", env_text)
    atomic_write(target_dir / "Makefile", makefile_text)


def _validate(input_model: RenderInput) -> None:
    """Reject obviously malformed RenderInput before any I/O happens."""
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
    # External-db invariants: the flow layer's _validate_external_db_inputs
    # rejects every realistic failure mode (missing host, missing /
    # malformed password file, identifier shell-escape, port range) with
    # operator-actionable PromptError messages. The two ValueError checks
    # below are a thin safety net for callers that bypass the flow (direct
    # render_files() invocations from tests / scripts) — they catch the
    # two unrecoverable invariants that would otherwise emit a broken
    # compose.yaml: empty host (no MARIADB_HOST resolution) and empty
    # password-file path (the EXTERNAL_DB_PASSWORD_FILE:?... compose
    # guard in compose.standalone.j2 catches it at up-time, but failing
    # at render time is cheaper).
    if input_model.use_external_db:
        if not input_model.external_db_host:
            raise ValueError("use_external_db=True requires external_db_host")
        if not input_model.external_db_password_file:
            raise ValueError(
                "use_external_db=True requires external_db_password_file"
            )
