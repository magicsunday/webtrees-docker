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

import re
from pathlib import Path

import pytest


# Repo root resolves from the test file: tests/ → installer/ → repo root.
# In the buildbox CI container only the installer/ dir is mounted, so
# parents[2] resolves to filesystem root — the scan then has nothing
# to walk and the test passes trivially (acceptable: the legacy-ref
# check is the gate for *new* contributor commits; CI ALSO runs the
# pytest suite against the full repo via ci-test-buildbox which mounts
# the full tree, and the standalone hosted CI runs in the actions
# checkout dir which IS the full repo).
_REPO_ROOT = Path(__file__).resolve().parents[2]


# Files where the nested `magicsunday/webtrees/X` form is intentionally
# kept. Add to this list ONLY with an accompanying comment in the
# touched file explaining why the legacy ref must stay.
#
# Update at WT-CLEANUP-97 time: the build.yml + README entries collapse
# once the dual-publish window closes.
_LEGACY_REF_ALLOWLIST = frozenset({
    # Build workflow: WT-CLEANUP-97 dual-publish blocks. Each of the
    # four build jobs emits both the flat canonical name and the legacy
    # nested alias. Removed when the deprecation window closes.
    ".github/workflows/build.yml",
    # README: image-name migration table (lines ~163-166) shows the
    # mapping from legacy → canonical; the legacy column is the whole
    # point of the table. README glossary + Editions table now use the
    # flat form.
    "README.md",
    # AGENTS.md Distribution row mentions the deprecation alias in the
    # same sentence as the canonical form, for completeness.
    "AGENTS.md",
    # docs/* sentences that name the legacy form alongside the canonical
    # to document the deprecation contract.
    "docs/developing.md",
    "docs/env-vars.md",
    # Historical planning + spec docs from the original design phase.
    # Touching these rewrites history without value; archive material.
    "docs/superpowers/plans/2026-05-11-out-of-the-box-self-host-phase1.md",
    "docs/superpowers/plans/2026-05-12-out-of-the-box-self-host-phase2a.md",
    "docs/superpowers/plans/2026-05-12-out-of-the-box-self-host-phase2b.md",
    "docs/superpowers/plans/2026-05-12-out-of-the-box-self-host-phase3.md",
    "docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md",
    # This test file references the legacy form in error messages and
    # in the allowlist comments above.
    "installer/tests/test_legacy_image_refs.py",
    # Negative assertions: these tests deliberately check that the
    # legacy form is ABSENT from rendered compose.yaml.
    "installer/tests/test_flow.py",
    "installer/tests/test_render.py",
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
