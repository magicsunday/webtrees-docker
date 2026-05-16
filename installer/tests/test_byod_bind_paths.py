"""Tests for #41 BYOD slice 2: host-path bind-mount for db data + media.

The new CLI flags (`--db-data-path`, `--media-path`) flip the rendered
named volumes from Docker-managed to bind-mount. The validator's job
is to refuse fast on missing / relative / non-directory paths,
system-tree paths, and non-MariaDB-shaped pre-populated directories;
the renderer's job is to write the right `driver_opts` block in
compose.yaml.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest
import yaml

from webtrees_installer.flow import (
    StandaloneArgs,
    _validate_byod_bind_paths,
)
from webtrees_installer.prompts import PromptError
from webtrees_installer.render import RenderInput, render_files
from webtrees_installer.versions import Catalog, PhpEntry


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(
            PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),
        ),
        nginx_tag="1.30-r1",
        installer_version="0.1.0",
    )


def _make_args(
    *,
    use_external_db: bool = False,
    db_data_path: str | None = None,
    media_path: str | None = None,
) -> StandaloneArgs:
    """Factory: baseline StandaloneArgs with the BYOD bind flags pluggable."""
    return StandaloneArgs(
        work_dir=None,
        interactive=False,
        edition="core",
        proxy_mode="standalone",
        app_port=28080,
        domain=None,
        traefik_network="traefik",
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        demo=False,
        demo_seed=42,
        enforce_https=False,
        pretty_urls=False,
        force=True,
        no_up=True,
        use_external_db=use_external_db,
        external_db_host="db.lan" if use_external_db else None,
        external_db_password_file="/tmp/pw" if use_external_db else None,
        db_data_path=db_data_path,
        media_path=media_path,
    )


def test_validator_accepts_valid_db_data_path(tmp_path: Path) -> None:
    """Happy path: existing empty directory on absolute path validates."""
    db_dir = tmp_path / "mariadb"
    db_dir.mkdir()
    _validate_byod_bind_paths(_make_args(db_data_path=str(db_dir)))


def test_validator_accepts_valid_media_path(tmp_path: Path) -> None:
    """Same shape for --media-path."""
    media_dir = tmp_path / "media"
    media_dir.mkdir()
    _validate_byod_bind_paths(_make_args(media_path=str(media_dir)))


def test_validator_rejects_relative_path(tmp_path: Path) -> None:
    """Compose bind-mounts resolve against the host root, so a relative
    path silently picks up the cwd at compose-up time — refuse loud."""
    with pytest.raises(PromptError, match="absolute"):
        _validate_byod_bind_paths(_make_args(db_data_path="data/mariadb"))


def test_validator_rejects_nonexistent_path(tmp_path: Path) -> None:
    """A missing path produces `mount: not found` at compose-up; refuse fast."""
    missing = tmp_path / "does-not-exist"
    with pytest.raises(PromptError, match="does not exist"):
        _validate_byod_bind_paths(_make_args(db_data_path=str(missing)))


def test_validator_rejects_file_not_directory(tmp_path: Path) -> None:
    """A regular file is not a valid bind-mount source for a volume."""
    f = tmp_path / "file.txt"
    f.write_text("oops")
    with pytest.raises(PromptError, match="not a directory"):
        _validate_byod_bind_paths(_make_args(media_path=str(f)))


def test_validator_rejects_db_data_path_with_external_db(tmp_path: Path) -> None:
    """--db-data-path is meaningless when the bundled db service is dropped;
    fail with an actionable message naming both flags."""
    db_dir = tmp_path / "mariadb"
    db_dir.mkdir()
    args = _make_args(use_external_db=True, db_data_path=str(db_dir))
    with pytest.raises(PromptError, match="--use-external-db"):
        _validate_byod_bind_paths(args)


def test_validator_accepts_media_path_with_external_db(tmp_path: Path) -> None:
    """--media-path remains valid with --use-external-db (media is
    independent of the DB service); no conflict."""
    media_dir = tmp_path / "media"
    media_dir.mkdir()
    args = _make_args(use_external_db=True, media_path=str(media_dir))
    _validate_byod_bind_paths(args)


@pytest.mark.parametrize(
    "system_path",
    ["/etc", "/var/log", "/usr/local/lib", "/home/user", "/root", "/bin"],
)
def test_validator_rejects_system_tree_paths(system_path: str) -> None:
    """A bind-mount onto a system tree causes the container's first-start
    chown to corrupt host ownership. Refuse with a dedicated message
    pointing at /srv/webtrees/* as the safer alternative."""
    with pytest.raises(PromptError, match="system tree"):
        _validate_byod_bind_paths(_make_args(db_data_path=system_path))


def test_validator_rejects_root_path() -> None:
    """Path `/` is its own special case — the message names the
    /srv/webtrees/* alternative instead of the system-tree wording."""
    with pytest.raises(PromptError, match="cannot be `/`"):
        _validate_byod_bind_paths(_make_args(media_path="/"))


def test_validator_rejects_db_data_path_with_postgres_marker(
    tmp_path: Path,
) -> None:
    """A directory containing PG_VERSION belongs to PostgreSQL — refuse to
    bind it as MariaDB's datadir."""
    db_dir = tmp_path / "wrong-rdbms"
    db_dir.mkdir()
    (db_dir / "PG_VERSION").write_text("17")
    with pytest.raises(PromptError, match="PostgreSQL"):
        _validate_byod_bind_paths(_make_args(db_data_path=str(db_dir)))


def test_validator_rejects_db_data_path_with_live_socket(
    tmp_path: Path,
) -> None:
    """A live mysql.sock means another engine is using this datadir;
    sharing corrupts InnoDB."""
    db_dir = tmp_path / "live"
    db_dir.mkdir()
    (db_dir / "mysql.sock").write_text("")
    with pytest.raises(PromptError, match="mysql.sock"):
        _validate_byod_bind_paths(_make_args(db_data_path=str(db_dir)))


def test_validator_rejects_db_data_path_with_unrelated_contents(
    tmp_path: Path,
) -> None:
    """A non-empty dir without the MariaDB marker files (`mysql/` subdir
    or `ibdata1`) is either the wrong RDBMS or unrelated data; refuse."""
    db_dir = tmp_path / "homedir"
    db_dir.mkdir()
    (db_dir / "myfile.txt").write_text("not a database")
    with pytest.raises(PromptError, match="does not look like"):
        _validate_byod_bind_paths(_make_args(db_data_path=str(db_dir)))


def test_validator_accepts_db_data_path_with_mariadb_marker(
    tmp_path: Path,
) -> None:
    """Pre-populated datadir with the canonical `mysql/` subdir validates
    (covers the legitimate --reuse path from an older install)."""
    db_dir = tmp_path / "preexisting"
    db_dir.mkdir()
    (db_dir / "mysql").mkdir()
    _validate_byod_bind_paths(_make_args(db_data_path=str(db_dir)))


def test_validator_accepts_db_data_path_with_ibdata1(tmp_path: Path) -> None:
    """ibdata1 alone (some restored MariaDB datadirs may carry it without
    a top-level mysql/ subdir) also counts as a valid marker."""
    db_dir = tmp_path / "preexisting"
    db_dir.mkdir()
    (db_dir / "ibdata1").write_text("")
    _validate_byod_bind_paths(_make_args(db_data_path=str(db_dir)))


def _make_render_input(
    catalog: Catalog,
    *,
    db_data_path: str = "",
    media_path: str = "",
) -> RenderInput:
    """Minimal RenderInput so tests can vary just the bind paths."""
    return RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=28080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 16, 12, 0, 0),
        db_data_path=db_data_path,
        media_path=media_path,
    )


def test_render_db_data_path_emits_bind_driver_opts(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """The `database:` volume must carry the bind driver_opts when
    db_data_path is set — otherwise compose ignores the host path."""
    inp = _make_render_input(catalog, db_data_path="/srv/webtrees/mariadb")
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    db_vol = compose["volumes"]["database"]
    assert db_vol["driver"] == "local"
    assert db_vol["driver_opts"]["type"] == "none"
    assert db_vol["driver_opts"]["device"] == "/srv/webtrees/mariadb"
    assert db_vol["driver_opts"]["o"] == "bind"


def test_render_media_path_emits_bind_driver_opts(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """Same shape on the `media:` volume."""
    inp = _make_render_input(catalog, media_path="/srv/webtrees/media")
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    media_vol = compose["volumes"]["media"]
    assert media_vol["driver"] == "local"
    assert media_vol["driver_opts"]["device"] == "/srv/webtrees/media"


def test_render_default_keeps_named_volumes(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """Regression guard: the default (no bind paths set) install must still
    render plain named volumes with no driver_opts block."""
    inp = _make_render_input(catalog)
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    # Plain named volumes serialise as `null` in YAML, surviving the
    # safe_load round-trip as Python None.
    assert compose["volumes"]["database"] is None
    assert compose["volumes"]["media"] is None


def test_render_rejects_db_data_path_with_external_db(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """The renderer's own _validate must enforce the same mutual exclusion
    the flow-layer validator catches — protects direct render_files callers."""
    inp = RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=28080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 16, 12, 0, 0),
        use_external_db=True,
        external_db_host="ext.lan",
        external_db_password_file="/tmp/pw",
        db_data_path="/srv/webtrees/mariadb",
    )
    with pytest.raises(ValueError, match="db_data_path"):
        render_files(input_model=inp, target_dir=tmp_path)


def test_render_media_path_works_with_external_db(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """--media-path stays compatible with --use-external-db — pin the
    contract that only --db-data-path is excluded."""
    inp = RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=28080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 16, 12, 0, 0),
        use_external_db=True,
        external_db_host="ext.lan",
        external_db_password_file="/tmp/pw",
        media_path="/srv/webtrees/media",
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    # No db: service (external db); but media: still bind-mounts.
    assert "db" not in compose["services"]
    assert compose["volumes"]["media"]["driver_opts"]["device"] == "/srv/webtrees/media"
