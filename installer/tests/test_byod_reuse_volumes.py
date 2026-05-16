"""Tests for #41 BYOD slice 3: --reuse-volumes <project>.

The flag pins the rendered stack's `database`, `media`, AND `secrets`
volumes to an existing compose project's named volumes via
`external: true`. The validator's job is to (a) refuse fast on a
malformed project name, (b) refuse fast when any of the three target
volumes is missing, (c) refuse when any target is currently mounted
by another container, (d) refuse when combined with another
mutually-exclusive BYOD flag. The renderer's job is to emit the right
`external: true` + `name:` shape on all three volumes.
"""

from __future__ import annotations

import subprocess
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from webtrees_installer.flow import (
    StandaloneArgs,
    _validate_byod_reuse_volumes,
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
    reuse_volumes_project: str | None = "wt_old",
    use_external_db: bool = False,
    db_data_path: str | None = None,
    media_path: str | None = None,
) -> StandaloneArgs:
    """Factory: baseline StandaloneArgs with --reuse-volumes set by default."""
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
        reuse_volumes_project=reuse_volumes_project,
    )


def _completed(returncode: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr,
    )


def _ok_inspect() -> subprocess.CompletedProcess[str]:
    return _completed(0)


def _missing_inspect() -> subprocess.CompletedProcess[str]:
    return _completed(1, stderr="Error: no such volume")


def _empty_ps() -> subprocess.CompletedProcess[str]:
    return _completed(0, stdout="")


def _running_ps(container_name: str) -> subprocess.CompletedProcess[str]:
    return _completed(0, stdout=container_name + "\n")


def _happy_path_side_effects() -> list[subprocess.CompletedProcess[str]]:
    """One inspect + one ps per volume, three volumes total = 6 calls."""
    return [
        _ok_inspect(), _empty_ps(),  # database
        _ok_inspect(), _empty_ps(),  # media
        _ok_inspect(), _empty_ps(),  # secrets
    ]


def test_validator_accepts_valid_project_with_all_three_volumes_present() -> None:
    """Happy path: project name valid, three volumes exist, none mounted."""
    with patch("subprocess.run", side_effect=_happy_path_side_effects()) as mock_run:
        _validate_byod_reuse_volumes(_make_args())
    # 3 volumes × 2 docker calls (inspect + ps) = 6.
    assert mock_run.call_count == 6


def test_validator_rejects_uppercase_project_name() -> None:
    """Compose project names are lowercase; reject uppercase to keep the
    rendered `external: true` reference compatible."""
    with pytest.raises(PromptError, match="lowercase"):
        _validate_byod_reuse_volumes(_make_args(reuse_volumes_project="WT_OLD"))


def test_validator_rejects_underscore_leading_project_name() -> None:
    """Compose disallows project names starting with _ or -."""
    with pytest.raises(PromptError, match="cannot start"):
        _validate_byod_reuse_volumes(_make_args(reuse_volumes_project="_old"))


def test_validator_rejects_missing_database_volume() -> None:
    """When docker volume inspect fails for <project>_database, refuse fast."""
    with patch(
        "subprocess.run",
        side_effect=[_missing_inspect()],
    ):
        with pytest.raises(PromptError, match="wt_old_database"):
            _validate_byod_reuse_volumes(_make_args())


def test_validator_rejects_missing_media_volume() -> None:
    """Same shape for the media volume — checked second."""
    with patch(
        "subprocess.run",
        side_effect=[
            _ok_inspect(), _empty_ps(),         # database OK
            _missing_inspect(),                  # media missing → raise
        ],
    ):
        with pytest.raises(PromptError, match="wt_old_media"):
            _validate_byod_reuse_volumes(_make_args())


def test_validator_rejects_missing_secrets_volume() -> None:
    """The secrets volume MUST be reused too — otherwise fresh random
    passwords mismatch the reused DB's user grants."""
    with patch(
        "subprocess.run",
        side_effect=[
            _ok_inspect(), _empty_ps(),         # database OK
            _ok_inspect(), _empty_ps(),         # media OK
            _missing_inspect(),                  # secrets missing → raise
        ],
    ):
        with pytest.raises(PromptError, match="wt_old_secrets"):
            _validate_byod_reuse_volumes(_make_args())


def test_validator_rejects_volume_currently_in_use() -> None:
    """A reused volume mounted by another running container would let two
    engines write the same datadir — InnoDB corruption. Refuse fast with
    the active container's name in the message."""
    with patch(
        "subprocess.run",
        side_effect=[
            _ok_inspect(), _running_ps("wt_old-db-1"),   # database in use
        ],
    ):
        with pytest.raises(PromptError, match="wt_old-db-1"):
            _validate_byod_reuse_volumes(_make_args())


def test_validator_surfaces_docker_daemon_unreachable_distinct_error() -> None:
    """A daemon-unreachable stderr must not be misreported as 'volume not found'."""
    with patch(
        "subprocess.run",
        side_effect=[
            _completed(
                1,
                stderr="Cannot connect to the Docker daemon at unix:///var/run/docker.sock",
            ),
        ],
    ):
        with pytest.raises(PromptError, match="daemon unreachable"):
            _validate_byod_reuse_volumes(_make_args())


def test_validator_surfaces_subprocess_timeout_as_promptError() -> None:
    """A docker probe that hangs past the timeout must surface as an
    operator-actionable PromptError, not a Python traceback."""
    with patch(
        "subprocess.run",
        side_effect=subprocess.TimeoutExpired(cmd="docker", timeout=10.0),
    ):
        with pytest.raises(PromptError, match="did not respond"):
            _validate_byod_reuse_volumes(_make_args())


def test_validator_surfaces_missing_docker_binary_as_promptError() -> None:
    """A FileNotFoundError from a missing docker binary must surface as a
    PromptError pointing the operator at the install gap."""
    with patch(
        "subprocess.run",
        side_effect=FileNotFoundError("[Errno 2] No such file or directory: 'docker'"),
    ):
        with pytest.raises(PromptError, match="docker CLI unavailable"):
            _validate_byod_reuse_volumes(_make_args())


@pytest.mark.parametrize(
    "kwargs,conflict_label",
    [
        ({"use_external_db": True}, "--use-external-db"),
        ({"db_data_path": "/srv/db"}, "--db-data-path"),
        ({"media_path": "/srv/media"}, "--media-path"),
    ],
)
def test_validator_rejects_combined_with_other_byod_flags(
    kwargs: dict[str, object], conflict_label: str,
) -> None:
    """--reuse-volumes is one-of-three; pair it with any other BYOD flag
    and the validator fails before any docker volume probe runs."""
    args = _make_args(**kwargs)
    with pytest.raises(PromptError, match=conflict_label):
        _validate_byod_reuse_volumes(args)


def test_render_reuse_volumes_pins_all_three_volumes_external(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """compose.yaml must mark `database:`, `media:`, AND `secrets:` as
    `external: true` with the right `name:` suffix — the secrets reuse
    is essential, otherwise the init container generates fresh random
    mariadb_password values that don't match the reused user grants."""
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
        reuse_volumes_project="wt_old",
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    for suffix in ("database", "media", "secrets"):
        vol = compose["volumes"][suffix]
        assert vol["external"] is True, f"{suffix} must be external"
        assert vol["name"] == f"wt_old_{suffix}"


def test_render_rejects_reuse_volumes_with_external_db(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """Renderer mirrors the flow-layer mutual-exclusion; protects direct
    render_files callers from producing an invalid compose."""
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
        reuse_volumes_project="wt_old",
    )
    with pytest.raises(ValueError, match="reuse_volumes_project"):
        render_files(input_model=inp, target_dir=tmp_path)


def test_render_default_unaffected_by_reuse_volumes_field(
    tmp_path: Path, catalog: Catalog,
) -> None:
    """Empty reuse_volumes_project must produce a plain named-volume
    compose, identical to the pre-slice-3 default — regression guard."""
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
    )
    render_files(input_model=inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    assert compose["volumes"]["database"] is None
    assert compose["volumes"]["media"] is None
    assert compose["volumes"]["secrets"] is None
