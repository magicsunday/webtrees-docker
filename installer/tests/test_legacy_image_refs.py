"""Repo-wide guard: the legacy nested image namespace must only appear
in expected places.

#58 migrated the canonical image names from `magicsunday/webtrees/X`
(nested) to `magicsunday/webtrees-X` (flat). The legacy nested form
stays published as a deprecation alias via WT-CLEANUP-97 (the four
dual-publish blocks in .github/workflows/build.yml). Outside those
intentionally-retained spots, any new occurrence of the nested form
is a regression — either a forgotten sweep or a contributor reverting
to the old shape.

The allowlist below enumerates every file that legitimately mentions
the nested form. A failure tells the contributor exactly where they
introduced a forbidden reference + what to do (either fix the ref or
expand the allowlist with rationale).
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest


def _resolve_repo_root() -> Path:
    """Resolve the repo root for the legacy-ref scan.

    Precedence:
    1. ``WT_REPO_ROOT`` env var — set by the ci-pytest container so the
       test can walk the full tree even though only ``installer/`` is
       the working dir.
    2. ``parents[2]`` of this file — works for host-shell pytest runs
       from any directory inside the repo (tests/ → installer/ → root).

    The marker-file check in ``_looks_like_repo_root`` is what actually
    decides whether the scan runs; this function just supplies the
    candidate path.
    """
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    return Path(__file__).resolve().parents[2]


_REPO_ROOT = _resolve_repo_root()


# Files where the nested `magicsunday/webtrees/X` form intentionally
# matches the regex below. With GH-97 closed, the build workflow no
# longer publishes the legacy alias and the README migration table is
# gone — the only legitimate residual hits are historical planning
# docs (archive material) and the test files themselves (negative
# assertions + this file's own positive-control fixture).
_LEGACY_REF_ALLOWLIST = frozenset({
    # Historical planning + spec docs from the original design phase.
    # Touching these rewrites history without value; archive material.
    "docs/superpowers/plans/2026-05-11-out-of-the-box-self-host-phase1.md",
    "docs/superpowers/plans/2026-05-12-out-of-the-box-self-host-phase2a.md",
    "docs/superpowers/plans/2026-05-12-out-of-the-box-self-host-phase2b.md",
    "docs/superpowers/plans/2026-05-12-out-of-the-box-self-host-phase3.md",
    "docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md",
    # Negative assertions: these tests deliberately check that the
    # legacy form is ABSENT from rendered compose.yaml.
    "installer/tests/test_flow.py",
    "installer/tests/test_render.py",
    # This file: the positive-control test seeds a tmp file with a
    # legacy ref to prove the scanner detects it; the literal string
    # also lives in the test source on disk.
    "installer/tests/test_legacy_image_refs.py",
})


# The match pattern: `magicsunday/webtrees/` followed by one of the
# four known image basenames. Anchored to avoid false positives like
# `magicsunday/webtrees-fan-chart` (a separate module repo).
_LEGACY_REF_RE = re.compile(r"magicsunday/webtrees/(?:php|nginx|installer)")


# Directories the scan must NOT descend into — VCS internals, vendored
# JS/PHP, caches, build artefacts.
_SKIP_DIRS = frozenset({
    ".git",
    ".venv",
    "__pycache__",
    "node_modules",
    "vendor",
    "build",
    "dist",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
})


def _looks_like_repo_root(root: Path) -> bool:
    """Sanity check: only scan when `root` actually contains the
    repo's marker files. In partial-mount CI containers, parents[2]
    can resolve to `/` and rglob would walk the whole filesystem."""
    return (root / "dev" / "versions.json").is_file() and (
        root / "installer" / "pyproject.toml"
    ).is_file()


def _scan_repo_for_legacy_refs(root: Path) -> set[str]:
    """Return repo-relative POSIX paths of every text file matching the
    legacy-ref pattern. Binary / oversized files are skipped silently."""
    hits: set[str] = set()
    if not _looks_like_repo_root(root):
        return hits
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in _SKIP_DIRS for part in path.relative_to(root).parts):
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if _LEGACY_REF_RE.search(content):
            hits.add(path.relative_to(root).as_posix())
    return hits


def test_no_legacy_nested_image_refs_outside_allowlist() -> None:
    """`magicsunday/webtrees/{php,nginx,installer}` must only appear in
    the deprecation-contract files. Any new occurrence elsewhere is
    a sweep miss.

    When the WT-CLEANUP-97 deprecation window closes, this test plus
    the allowlist get pruned to whatever stays (likely just the
    historical superpowers docs).
    """
    # In a partial-mount CI container only `installer/` is visible, so
    # `_REPO_ROOT` cannot reach the repo's marker files; skip in that
    # case. The host-shell run (`make ci-pytest` against the full repo,
    # or `make ci-test-buildbox` which mounts the whole tree) is the
    # authoritative gate.
    if not _looks_like_repo_root(_REPO_ROOT):
        pytest.skip(
            f"repo root not reachable from {_REPO_ROOT} — running in a "
            f"partial-mount container; the full-tree run is authoritative."
        )
    hits = _scan_repo_for_legacy_refs(_REPO_ROOT)
    unexpected = hits - _LEGACY_REF_ALLOWLIST
    if unexpected:
        pytest.fail(
            "Legacy nested image refs found outside the allowlist:\n  "
            + "\n  ".join(sorted(unexpected))
            + "\n\nEither migrate to the flat canonical name "
            "(`magicsunday/webtrees-{php,nginx,installer}`) or add the "
            "file to _LEGACY_REF_ALLOWLIST in this test with a comment "
            "explaining why the legacy reference must stay during the "
            "deprecation window."
        )


def test_scanner_detects_a_seeded_legacy_ref(tmp_path: Path) -> None:
    """Positive-control: a tmp tree carrying a forbidden ref must be
    detected. Catches a future refactor where `_scan_repo_for_legacy_refs`
    silently returns an empty set (which would make the guard above
    pass-by-accident on a clean tree)."""
    # Marker files so _looks_like_repo_root() succeeds against tmp_path.
    (tmp_path / "dev").mkdir()
    (tmp_path / "dev" / "versions.json").write_text("[]")
    (tmp_path / "installer").mkdir()
    (tmp_path / "installer" / "pyproject.toml").write_text("")

    offender = tmp_path / "fake-compose.yaml"
    offender.write_text("image: ghcr.io/magicsunday/webtrees/php:1.0\n")

    hits = _scan_repo_for_legacy_refs(tmp_path)
    # Equality (not containment) so an over-broad refactor that
    # accidentally returns every file in the tmp tree fails loud.
    assert hits == {"fake-compose.yaml"}


def test_resolve_repo_root_honours_env_override(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`WT_REPO_ROOT` env var must win over `parents[2]` so a future
    Make/ci.mk edit that drops the `-e WT_REPO_ROOT=/repo` line — or
    a typo in the env-var name — gets caught here instead of silently
    re-introducing the Round-3 'guard always skips' bug."""
    monkeypatch.setenv("WT_REPO_ROOT", str(tmp_path))
    assert _resolve_repo_root() == tmp_path


def test_resolve_repo_root_falls_back_when_env_unset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without WT_REPO_ROOT, fall back to parents[2] of the test file."""
    monkeypatch.delenv("WT_REPO_ROOT", raising=False)
    expected = Path(__file__).resolve().parents[2]
    assert _resolve_repo_root() == expected


def test_resolve_repo_root_treats_empty_env_as_unset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An empty-string env var falls through to the parents[2] path —
    avoids `Path('')` ever reaching the marker-file check (which would
    silently resolve to cwd)."""
    monkeypatch.setenv("WT_REPO_ROOT", "")
    expected = Path(__file__).resolve().parents[2]
    assert _resolve_repo_root() == expected


def test_scanner_ignores_module_repo_slugs(tmp_path: Path) -> None:
    """Negative-control: the hyphenated module-repo form
    (`magicsunday/webtrees-fan-chart`) must NOT match — those are
    separate repositories, not deprecated aliases."""
    (tmp_path / "dev").mkdir()
    (tmp_path / "dev" / "versions.json").write_text("[]")
    (tmp_path / "installer").mkdir()
    (tmp_path / "installer" / "pyproject.toml").write_text("")

    decoy = tmp_path / "module-link.md"
    decoy.write_text("See magicsunday/webtrees-fan-chart for the chart.\n")

    hits = _scan_repo_for_legacy_refs(tmp_path)
    assert hits == set(), f"unexpected hits: {hits}"
