"""Tests for the dev-flow renderer."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest

from webtrees_installer.dev_flow import DevArgs, build_compose_chain, render_dev_env
from webtrees_installer.versions import Catalog, PhpEntry


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),),
        nginx_tag="1.28-r1",
        installer_version="0.1.0",
    )


def _args(**overrides) -> DevArgs:
    defaults = dict(
        work_dir=None,
        interactive=False,
        proxy_mode="standalone",
        dev_domain="webtrees.localhost:50010",
        app_port=50010,
        pma_port=50011,
        mariadb_host="db",
        mariadb_database="webtrees",
        mariadb_user="webtrees",
        mariadb_password="devpw",
        mariadb_root_password="rootpw",
        use_existing_db=False,
        use_external_db=False,
        local_user_id=1000,
        local_user_name="dev",
        force=True,
    )
    defaults.update(overrides)
    return DevArgs(**defaults)


def test_build_compose_chain_standalone() -> None:
    assert (
        build_compose_chain(proxy_mode="standalone", use_external_db=False)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml"
    )


def test_build_compose_chain_traefik() -> None:
    assert (
        build_compose_chain(proxy_mode="traefik", use_external_db=False)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.traefik.yaml"
    )


def test_build_compose_chain_standalone_with_external_db() -> None:
    assert (
        build_compose_chain(proxy_mode="standalone", use_external_db=True)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml:compose.external.yaml"
    )


def test_render_dev_env_writes_full_env(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "ENVIRONMENT=development" in env
    assert "COMPOSE_PROJECT_NAME=webtrees" in env
    assert "PHP_VERSION=8.5" in env
    assert "WEBTREES_VERSION=2.2.6" in env
    assert "WEBTREES_NGINX_VERSION=1.28-r1" in env
    assert "MARIADB_PASSWORD=devpw" in env
    assert "MARIADB_ROOT_PASSWORD=rootpw" in env
    assert "USE_EXISTING_DB=0" in env
    assert "LOCAL_USER_ID=1000" in env
    assert "APP_PORT=50010" in env
    assert "PMA_PORT=50011" in env
    assert "compose.publish.yaml" in env
    assert "compose.traefik.yaml" not in env
    assert "ENFORCE_HTTPS=FALSE" in env


def test_render_dev_env_traefik_drops_app_port(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path, proxy_mode="traefik",
                 dev_domain="webtrees.example.org", app_port=None, pma_port=None)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.traefik.yaml" in env
    assert "compose.publish.yaml" not in env
    assert "APP_PORT" not in env
    assert "PMA_PORT" not in env
    assert "ENFORCE_HTTPS=TRUE" in env


def test_render_dev_env_external_db_appends_compose_file(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path, use_external_db=True, mariadb_host="external-db.local")
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.external.yaml" in env
    assert "MARIADB_HOST=external-db.local" in env


def test_render_dev_env_rejects_traefik_without_domain(tmp_path: Path, catalog: Catalog) -> None:
    """Traefik mode demands a non-empty dev_domain."""
    args = _args(work_dir=tmp_path, proxy_mode="traefik", dev_domain="",
                 app_port=None, pma_port=None)
    with pytest.raises(ValueError, match="dev_domain"):
        render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                       generated_at=datetime(2026, 5, 12, 12, 0, 0))
