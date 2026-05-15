"""Tests for the template renderer."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest
import yaml

from webtrees_installer._alpine import ALPINE_BASE_IMAGE
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
        nginx_tag="1.30-r1",
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

    phpfpm = compose["services"]["phpfpm"]
    assert "php-full" not in phpfpm["image"]
    assert phpfpm["image"].endswith(":2.2.6-php8.5")
    assert "WT_ADMIN_USER" not in phpfpm["environment"]

    nginx_ports = compose["services"]["nginx"]["ports"]
    assert any("8080" in p for p in nginx_ports)

    assert "APP_PORT=8080" in env


def test_render_standalone_uses_canonical_alpine_pin(tmp_path: Path, standalone_core: RenderInput) -> None:
    """Standalone init service must pin the canonical Alpine image."""
    render_files(input_model=standalone_core, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    assert compose["services"]["init"]["image"] == ALPINE_BASE_IMAGE


def test_render_traefik_uses_canonical_alpine_pin(tmp_path: Path, catalog: Catalog) -> None:
    """Traefik variant must pin the same canonical Alpine image."""
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

    assert compose["services"]["init"]["image"] == ALPINE_BASE_IMAGE


def test_render_omits_project_name(tmp_path: Path, standalone_core: RenderInput) -> None:
    """A hardcoded `name:` in compose.yaml or `COMPOSE_PROJECT_NAME=` in .env
    collides on the same host when two installs sit in different directories
    — compose would treat them as the same project and recreate the live
    stack with the sibling's image set. Letting compose derive the project
    from the cwd basename keeps the canonical install identical and gives
    every other directory its own isolated stack.
    """
    render_files(input_model=standalone_core, target_dir=tmp_path)

    compose_text = (tmp_path / "compose.yaml").read_text()
    env_text = (tmp_path / ".env").read_text()

    for line in compose_text.splitlines():
        assert not line.lower().startswith("name:"), (
            f"compose.yaml must not declare a project name; found: {line!r}"
        )

    compose = yaml.safe_load(compose_text)
    assert "name" not in compose

    for line in env_text.splitlines():
        assert not line.startswith("COMPOSE_PROJECT_NAME="), (
            f".env must not pin COMPOSE_PROJECT_NAME; found: {line!r}"
        )


def test_render_traefik_omits_project_name(tmp_path: Path, catalog: Catalog) -> None:
    """Traefik variant must also rely on cwd-derived project naming."""
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

    compose_text = (tmp_path / "compose.yaml").read_text()
    env_text = (tmp_path / ".env").read_text()

    for line in compose_text.splitlines():
        assert not line.lower().startswith("name:"), (
            f"compose.yaml must not declare a project name; found: {line!r}"
        )
    for line in env_text.splitlines():
        assert not line.startswith("COMPOSE_PROJECT_NAME="), (
            f".env must not pin COMPOSE_PROJECT_NAME; found: {line!r}"
        )


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


def test_render_pretty_urls_default_off_writes_rewrite_urls_zero(
    tmp_path: Path, standalone_core: RenderInput,
) -> None:
    """Default render path (pretty_urls=False) ships WEBTREES_REWRITE_URLS=0."""
    render_files(input_model=standalone_core, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    assert compose["services"]["phpfpm"]["environment"]["WEBTREES_REWRITE_URLS"] == "0"


def test_render_pretty_urls_on_writes_rewrite_urls_one_standalone(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """`pretty_urls=True` flips WEBTREES_REWRITE_URLS to "1" on the standalone phpfpm service."""
    inp = RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=28080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
        pretty_urls=True,
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    assert compose["services"]["phpfpm"]["environment"]["WEBTREES_REWRITE_URLS"] == "1"


def test_render_pretty_urls_on_writes_rewrite_urls_one_traefik(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """Traefik proxy mode honours pretty_urls=True identically."""
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
        pretty_urls=True,
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    assert compose["services"]["phpfpm"]["environment"]["WEBTREES_REWRITE_URLS"] == "1"


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


_PROXY_VARIANTS = (
    pytest.param("standalone", 8080, None, id="standalone"),
    pytest.param("traefik", None, "webtrees.example.com", id="traefik"),
)


@pytest.mark.parametrize("proxy_mode,app_port,domain", _PROXY_VARIANTS)
def test_render_writes_enforce_https_true_by_default(
    tmp_path: Path, catalog: Catalog,
    proxy_mode: str, app_port: int | None, domain: str | None,
) -> None:
    """Default render (enforce_https=True) sets ENFORCE_HTTPS=TRUE on phpfpm + nginx in both proxy modes."""
    inp = RenderInput(
        edition="core",
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    assert compose["services"]["phpfpm"]["environment"]["ENFORCE_HTTPS"] == "TRUE"
    assert compose["services"]["nginx"]["environment"]["ENFORCE_HTTPS"] == "TRUE"


@pytest.mark.parametrize("proxy_mode,app_port,domain", _PROXY_VARIANTS)
def test_render_writes_enforce_https_false_when_opted_out(
    tmp_path: Path, catalog: Catalog,
    proxy_mode: str, app_port: int | None, domain: str | None,
) -> None:
    """enforce_https=False flips ENFORCE_HTTPS=FALSE on both phpfpm and nginx in both proxy modes."""
    inp = RenderInput(
        edition="core",
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
        enforce_https=False,
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    assert compose["services"]["phpfpm"]["environment"]["ENFORCE_HTTPS"] == "FALSE"
    assert compose["services"]["nginx"]["environment"]["ENFORCE_HTTPS"] == "FALSE"


@pytest.mark.parametrize("proxy_mode,app_port,domain", _PROXY_VARIANTS)
@pytest.mark.parametrize("enforce_https", [True, False])
def test_render_nginx_healthcheck_carries_x_forwarded_proto(
    tmp_path: Path, catalog: Catalog,
    proxy_mode: str, app_port: int | None, domain: str | None,
    enforce_https: bool,
) -> None:
    """The probe sends X-Forwarded-Proto: https unconditionally so the
    enforce-https 301 never turns a curl exit code into a false-positive
    healthy state. The header must survive on both proxy modes AND
    regardless of the enforce_https value (decoupling claim documented
    in the template comment)."""
    inp = RenderInput(
        edition="core",
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
        enforce_https=enforce_https,
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    healthcheck = compose["services"]["nginx"]["healthcheck"]["test"]
    # Anchor on the -H flag form so a future edit that drops the curl flag
    # while leaving the header text in a comment cannot mask a regression.
    assert any(
        "-H 'X-Forwarded-Proto: https'" in part for part in healthcheck
    )


def test_render_template_parity_enforce_https_and_healthcheck(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """Mirrored fields between the two proxy templates must stay in
    lockstep: the ENFORCE_HTTPS env on phpfpm + nginx, and the nginx
    healthcheck `test` array (the curl command line). Per
    feedback_lockstep_check_pattern, this guard fails loud if a future
    edit fixes one template and forgets the other.

    Intentionally narrow: timing knobs on the healthcheck stanza
    (`interval`, `timeout`, `retries`, `start_period`) can legitimately
    diverge per topology in the future (e.g. Traefik edge giving the
    backend a longer warm-up budget), so they are not pinned here.
    """
    standalone_dir = tmp_path / "standalone"
    traefik_dir = tmp_path / "traefik"
    standalone_dir.mkdir()
    traefik_dir.mkdir()

    base_kwargs = {
        "edition": "core",
        "admin_bootstrap": False,
        "admin_user": None,
        "admin_email": None,
        "catalog": catalog,
        "generated_at": datetime(2026, 5, 12, 12, 0, 0),
    }
    render_files(
        input_model=RenderInput(
            proxy_mode="standalone", app_port=8080, domain=None, **base_kwargs,
        ),
        target_dir=standalone_dir,
    )
    render_files(
        input_model=RenderInput(
            proxy_mode="traefik", app_port=None,
            domain="webtrees.example.com", **base_kwargs,
        ),
        target_dir=traefik_dir,
    )

    standalone = yaml.safe_load((standalone_dir / "compose.yaml").read_text())
    traefik = yaml.safe_load((traefik_dir / "compose.yaml").read_text())

    for svc in ("phpfpm", "nginx"):
        assert (
            standalone["services"][svc]["environment"]["ENFORCE_HTTPS"]
            == traefik["services"][svc]["environment"]["ENFORCE_HTTPS"]
        ), f"ENFORCE_HTTPS mismatch on service {svc}"

    assert (
        standalone["services"]["nginx"]["healthcheck"]["test"]
        == traefik["services"]["nginx"]["healthcheck"]["test"]
    ), "nginx healthcheck curl command diverged between standalone and traefik templates"

    # Symmetry guard: legitimate per-topology divergence is fine for the
    # timing fields (kept open by the narrow `test` comparison above),
    # but a future single-side edit that adds an unknown key (e.g.
    # `disable: true`, `start_interval: 1s`) to one template only would
    # slip past the curl-line check. Pin the field set to flag asymmetry.
    assert (
        set(standalone["services"]["nginx"]["healthcheck"].keys())
        == set(traefik["services"]["nginx"]["healthcheck"].keys())
    ), "nginx healthcheck stanza key sets diverged between standalone and traefik templates"

    # Positive guard: a synchronized edit that adds `disable: true` to
    # BOTH templates or replaces the curl with a no-op would slip past
    # the symmetry checks (they assert sameness, not enabledness). Pin
    # the probe as enabled and shell-driven.
    for mode, compose_doc in (("standalone", standalone), ("traefik", traefik)):
        healthcheck = compose_doc["services"]["nginx"]["healthcheck"]
        assert "disable" not in healthcheck, (
            f"{mode}: nginx healthcheck must not be disabled"
        )
        assert healthcheck["test"][0] == "CMD-SHELL", (
            f"{mode}: nginx healthcheck must run a CMD-SHELL probe"
        )


@pytest.mark.parametrize("proxy_mode,app_port,domain", _PROXY_VARIANTS)
def test_render_nginx_healthcheck_start_period_pinned(
    tmp_path: Path, catalog: Catalog,
    proxy_mode: str, app_port: int | None, domain: str | None,
) -> None:
    """start_period: 60s covers cold first-boot on slow disks (NAS spinning
    rust, AUTO_SEED running schema migrations). A revert to a smaller value
    would silently re-introduce the false-`unhealthy` window the R2 audit
    closed; pin the number so an accidental tightening fails loud."""
    inp = RenderInput(
        edition="core",
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    assert compose["services"]["nginx"]["healthcheck"]["start_period"] == "60s"


def test_render_traefik_carries_websecure_tls_labels(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """The TRAEFIK_TLS_INCOMPAT_REASON guard text in prompts.py promises
    operators that the Traefik router still terminates TLS at the edge
    (`websecure` entrypoint + `tls=true`). Pin those labels here so the
    guard rationale cannot silently rot when the template is edited."""
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

    labels = compose["services"]["nginx"]["labels"]
    assert labels["traefik.http.routers.webtrees.entrypoints"] == "websecure"
    # yaml.safe_load coerces unquoted `true` / `yes` / `on` to Python bool;
    # the current template quotes it ("true") so safe_load yields a string,
    # but a legitimate future de-quoting would still keep the router on TLS.
    # Compare loosely so the test pins operational semantics, not YAML form.
    tls_label = labels["traefik.http.routers.webtrees.tls"]
    assert str(tls_label).lower() in {"true", "yes", "on"}


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
