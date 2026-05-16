"""Tests for `scripts/bump-mariadb.py`.

Mirrors the test layout of `test_bump_nginx.py` — the bump tool is
one-shot operator tooling; `test_mariadb_pin_lockstep` is the safety
net. These tests pin the bumper's contract so a regression cannot
leave the working tree half-mutated silently.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest


def _resolve_repo_root() -> Path | None:
    """Resolve the repo root using the WT_REPO_ROOT precedence pattern."""
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


def _load_bumper() -> ModuleType:
    """Load `scripts/bump-mariadb.py` by file path with fail-loud guard."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "bump-mariadb.py"
    if not script.is_file():
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"contain scripts/bump-mariadb.py."
            )
        pytest.skip(f"bumper script missing: {script}")
    spec = importlib.util.spec_from_file_location("bump_mariadb", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def bumper() -> ModuleType:
    """The bumper module, loaded once per test module."""
    return _load_bumper()


def _seed_repo(root: Path, minor: str = "11.8") -> None:
    """Write minimal canonical + the four mirror sites under `root`."""
    canonical_dir = root / "installer" / "webtrees_installer" / "templates"
    canonical_dir.mkdir(parents=True, exist_ok=True)
    (canonical_dir / "compose.standalone.j2").write_text(
        f"services:\n  db:\n    image: mariadb:{minor}\n",
        encoding="utf-8",
    )
    (canonical_dir / "compose.traefik.j2").write_text(
        f"services:\n  db:\n    image: mariadb:{minor}\n",
        encoding="utf-8",
    )
    (root / "compose.yaml").write_text(
        f"services:\n  db:\n    image: mariadb:{minor}\n",
        encoding="utf-8",
    )
    (root / "templates" / "portainer").mkdir(parents=True, exist_ok=True)
    (root / "templates" / "portainer" / "compose.yaml").write_text(
        f"services:\n  db:\n    image: mariadb:{minor}\n",
        encoding="utf-8",
    )


def test_bump_syncs_all_four_pin_sites(
    bumper: ModuleType, tmp_path: Path
) -> None:
    """Happy path: 11.8 -> 11.9. All four mirror sites get the new pin."""
    _seed_repo(tmp_path, "11.8")
    rc = bumper.bump(tmp_path, "11.9")
    assert rc == 0
    for relative in (
        "installer/webtrees_installer/templates/compose.standalone.j2",
        "installer/webtrees_installer/templates/compose.traefik.j2",
        "compose.yaml",
        "templates/portainer/compose.yaml",
    ):
        body = (tmp_path / relative).read_text(encoding="utf-8")
        assert "image: mariadb:11.9" in body
        assert "image: mariadb:11.8" not in body


def test_bump_preserves_trailing_comment(
    bumper: ModuleType, tmp_path: Path
) -> None:
    """A trailing YAML comment on the image line (`# rolling-minor`) must
    survive the substitution — the line shape is preserved."""
    _seed_repo(tmp_path, "11.8")
    canonical = tmp_path / "installer" / "webtrees_installer" / "templates" / "compose.standalone.j2"
    canonical.write_text(
        "services:\n  db:\n    image: mariadb:11.8  # rolling-minor\n",
        encoding="utf-8",
    )
    rc = bumper.bump(tmp_path, "11.9")
    assert rc == 0
    body = canonical.read_text(encoding="utf-8")
    assert "image: mariadb:11.9  # rolling-minor" in body


def test_bump_rejects_same_minor(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Idempotency: re-bumping the already-pinned minor is a no-op the
    operator must explicitly intend (by passing a different minor)."""
    _seed_repo(tmp_path, "11.8")
    rc = bumper.bump(tmp_path, "11.8")
    assert rc == 1
    assert "already at mariadb:11.8" in capsys.readouterr().err


def test_bump_rejects_patch_pinned_minor(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Pin policy: X.Y only. A `11.9.3` argv must fail with an
    actionable error rather than silently writing a patch pin."""
    _seed_repo(tmp_path, "11.8")
    rc = bumper.bump(tmp_path, "11.9.3")
    assert rc == 1
    assert "must match X.Y" in capsys.readouterr().err


def test_bump_fails_loud_when_canonical_missing(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """No canonical compose.standalone.j2: refuse rather than write
    a partial bump."""
    rc = bumper.bump(tmp_path, "11.9")
    assert rc == 1
    assert "canonical pin not found" in capsys.readouterr().err


def test_bump_fails_loud_when_mirror_lacks_pin_literal(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A mirror site without the expected `image: mariadb:X.Y` literal
    is a structural-drift indicator."""
    _seed_repo(tmp_path, "11.8")
    (tmp_path / "compose.yaml").write_text(
        "services:\n  db:\n    image: postgres:16\n",
        encoding="utf-8",
    )
    rc = bumper.bump(tmp_path, "11.9")
    assert rc == 1
    err = capsys.readouterr().err
    assert "mirror sync failed" in err
    assert "compose.yaml" in err


def test_main_rejects_wrong_argv_count(
    bumper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Defensive: a wrong invocation must fail with exit 2 and a usage hint."""
    monkeypatch.setattr(sys, "argv", ["bump-mariadb"])
    rc = bumper.main()
    assert rc == 2
    assert "usage:" in capsys.readouterr().err


def test_script_is_executable_under_python3() -> None:
    """Smoke-execute the script as a subprocess to catch syntax-level
    regressions at PR time."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "bump-mariadb.py"
    if not script.is_file():
        pytest.skip(f"bumper script missing: {script}")
    result = subprocess.run(
        [sys.executable, str(script)],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 2
    assert "usage:" in result.stderr
