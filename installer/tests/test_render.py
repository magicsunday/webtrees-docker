"""Tests for the template renderer."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest
import yaml

from webtrees_installer.render import (
    RenderInput,
    render_files,
)
from webtrees_installer.versions import Catalog, PhpEntry


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(
            PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),
            PhpEntry(webtrees="2.2.6", php="8.4"),
        ),
        nginx_tag="1.28-r1",
        installer_version="0.1.0",
    )


@pytest.fixture
def standalone_core(catalog: Catalog) -> RenderInput:
    return RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=8080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )


def test_render_standalone_core(tmp_path: Path, standalone_core: RenderInput) -> None:
    render_files(input_model=standalone_core, target_dir=tmp_path)

    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    env = (tmp_path / ".env").read_text()

    assert compose["name"] == "webtrees"
    phpfpm = compose["services"]["phpfpm"]
    assert "php-full" not in phpfpm["image"]
    assert phpfpm["image"].endswith(":2.2.6-php8.5")
    assert "WT_ADMIN_USER" not in phpfpm["environment"]

    nginx_ports = compose["services"]["nginx"]["ports"]
    assert any("8080" in p for p in nginx_ports)

    assert "APP_PORT=8080" in env
    assert "COMPOSE_PROJECT_NAME=webtrees" in env


def test_init_command_escapes_shell_vars(tmp_path: Path, standalone_core: RenderInput) -> None:
    """The init service's secret-seeding loop references $name inside a YAML
    block scalar. Compose v2 interpolates `$VAR` in command strings against
    the host env at up-time, so a bare `$name` collapses to empty and the
    redirect lands on `/secrets/` — the directory — and exit 1. The template
    must escape with `$$name` so compose unwraps to a literal `$name` for
    the in-container shell to expand.
    """
    render_files(input_model=standalone_core, target_dir=tmp_path)
    compose_text = (tmp_path / "compose.yaml").read_text()

    assert "$$name" in compose_text, "init command must escape $name as $$name"
    # Belt: no bare `$name` survives — only `$$name` allowed.
    for line in compose_text.splitlines():
        if "/secrets/$" in line:
            assert "/secrets/$$name" in line, f"bare $name leak on: {line!r}"


def test_render_standalone_full_with_admin(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="full",
        proxy_mode="standalone",
        app_port=80,
        domain=None,
        admin_bootstrap=True,
        admin_user="admin",
        admin_email="admin@example.org",
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    phpfpm = compose["services"]["phpfpm"]
    assert "/php-full:" in phpfpm["image"]
    assert phpfpm["environment"]["WT_ADMIN_USER"] == "admin"
    assert phpfpm["environment"]["WT_ADMIN_EMAIL"] == "admin@example.org"
    assert (
        phpfpm["environment"]["WT_ADMIN_PASSWORD_FILE"]
        == "/secrets/wt_admin_password"
    )


def test_render_traefik(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="core",
        proxy_mode="traefik",
        app_port=None,
        domain="webtrees.example.com",
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    env = (tmp_path / ".env").read_text()

    assert "traefik" in compose["networks"]
    assert compose["networks"]["traefik"]["external"] is True
    assert compose["networks"]["traefik"]["name"] == "traefik"

    nginx = compose["services"]["nginx"]
    assert "ports" not in nginx
    labels = nginx["labels"]
    assert (
        labels["traefik.http.routers.webtrees.rule"]
        == "Host(`webtrees.example.com`)"
    )
    assert labels["traefik.docker.network"] == "traefik"
    assert "APP_PORT" not in env


def test_render_traefik_with_custom_network(tmp_path: Path, catalog: Catalog) -> None:
    """Custom traefik_network propagates to both network name and docker.network label."""
    inp = RenderInput(
        edition="core",
        proxy_mode="traefik",
        app_port=None,
        domain="webtrees.example.com",
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
        traefik_network="my-proxy",
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    assert compose["networks"]["traefik"]["name"] == "my-proxy"
    assert (
        compose["services"]["nginx"]["labels"]["traefik.docker.network"]
        == "my-proxy"
    )


def test_render_rejects_invalid_proxy_mode(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="core",
        proxy_mode="nope",
        app_port=8080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    with pytest.raises(ValueError, match="proxy_mode"):
        render_files(input_model=inp, target_dir=tmp_path)


def test_render_rejects_admin_without_credentials(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=8080,
        domain=None,
        admin_bootstrap=True,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    with pytest.raises(ValueError, match="admin_user"):
        render_files(input_model=inp, target_dir=tmp_path)


def test_render_creates_missing_target_dir(tmp_path: Path, standalone_core: RenderInput) -> None:
    """target_dir is created if it does not exist (parents=True)."""
    nested = tmp_path / "deep" / "nested" / "work"
    assert not nested.exists()

    render_files(input_model=standalone_core, target_dir=nested)

    assert (nested / "compose.yaml").is_file()
    assert (nested / ".env").is_file()


def test_render_leaves_no_tmp_files(tmp_path: Path, standalone_core: RenderInput) -> None:
    """Atomic write must rename the .tmp files; none should linger after a successful run."""
    render_files(input_model=standalone_core, target_dir=tmp_path)

    leftovers = sorted(p.name for p in tmp_path.iterdir() if p.name.endswith(".tmp"))
    assert leftovers == []


def test_render_rejects_file_at_target_dir(tmp_path: Path, standalone_core: RenderInput) -> None:
    """target_dir pointing at a regular file → clear NotADirectoryError."""
    file_target = tmp_path / "not-a-dir"
    file_target.write_text("oops")

    with pytest.raises(NotADirectoryError, match="not a directory"):
        render_files(input_model=standalone_core, target_dir=file_target)
