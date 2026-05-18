"""Tests for flow._validate_db_type_compatibility (#144).

SQLite has no network listener (no host:port to point
``--use-external-db`` at) and no ``/var/lib/mysql`` to bind-mount via
``--db-data-path``. ``--reuse-volumes`` IS compatible because the
sqlite file rides inside the ``app`` volume that the reuse-pattern
already covers. The validator turns both incompatible shapes into
operator-actionable PromptErrors with exit-code 2 (same channel as
every other prompt failure).
"""

from __future__ import annotations

import pytest

from webtrees_installer.flow import (
    StandaloneArgs,
    _validate_db_type_compatibility,
)
from webtrees_installer.prompts import PromptError


def _make_args(
    *,
    db_type: str = "sqlite",
    use_external_db: bool = False,
    db_data_path: str | None = None,
    reuse_volumes_project: str | None = None,
) -> StandaloneArgs:
    """Factory: a baseline sqlite StandaloneArgs, customise via kwargs."""
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
        db_type=db_type,
        use_external_db=use_external_db,
        db_data_path=db_data_path,
        reuse_volumes_project=reuse_volumes_project,
    )


def test_mariadb_default_passes() -> None:
    """Non-sqlite shape skips the validator entirely (early return)."""
    _validate_db_type_compatibility(_make_args(db_type="mariadb"))


def test_sqlite_alone_passes() -> None:
    """Plain --db sqlite with no BYOD flag is the simplest happy path."""
    _validate_db_type_compatibility(_make_args(db_type="sqlite"))


def test_sqlite_plus_external_db_rejected() -> None:
    """--db sqlite + --use-external-db is incompatible (no network listener)."""
    args = _make_args(db_type="sqlite", use_external_db=True)
    with pytest.raises(PromptError, match="--use-external-db"):
        _validate_db_type_compatibility(args)


def test_sqlite_plus_db_data_path_rejected(tmp_path) -> None:  # noqa: ANN001
    """--db sqlite + --db-data-path is incompatible (no /var/lib/mysql)."""
    args = _make_args(db_type="sqlite", db_data_path=str(tmp_path))
    with pytest.raises(PromptError, match="--db-data-path"):
        _validate_db_type_compatibility(args)


def test_sqlite_plus_reuse_volumes_passes() -> None:
    """--db sqlite + --reuse-volumes IS allowed — the sqlite file rides in app:."""
    args = _make_args(db_type="sqlite", reuse_volumes_project="wt-prev")
    _validate_db_type_compatibility(args)
