"""Shared pytest fixtures."""

from __future__ import annotations

import os
from pathlib import Path

import pytest


@pytest.fixture(scope="session")
def resolved_repo_root() -> Path | None:
    """Resolve the repo root for tests that read files outside `installer/`.

    Precedence:
    1. ``WT_REPO_ROOT`` env var, set by Make/ci.mk's ci-pytest so a test
       can walk the full tree even though only ``installer/`` is the
       working dir.
    2. ``parents[2]`` of this file, which works for host-shell pytest runs
       from inside the repo.

    Returns ``None`` when neither candidate exists (``parents[2]`` raises
    IndexError). The caller decides whether that skips or fails loud, and
    whether the candidate is a real repo root.
    """
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


def _looks_like_repo_root(candidate: Path) -> bool:
    """Tell whether a path is the real repo root.

    A path is the root iff both `dev/versions.json` and
    `installer/pyproject.toml` exist underneath it, a pair that is unique to
    this repo.
    """
    return (candidate / "dev" / "versions.json").is_file() and (
        candidate / "installer" / "pyproject.toml"
    ).is_file()


@pytest.fixture
def validated_repo_root(resolved_repo_root: Path | None) -> Path:
    """Return the repo root, skipping on a partial checkout.

    When `WT_REPO_ROOT` is set it is the load-bearing wire of CI, so a value
    that is not a real root fails loud instead of skipping.
    """
    if resolved_repo_root is None or not _looks_like_repo_root(resolved_repo_root):
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"resolve to a real repo root. Fix the bind-mount in "
                f"Make/ci.mk's ci-pytest target."
            )
        pytest.skip(
            f"repo root not reachable from {resolved_repo_root}. Running from "
            f"an installed wheel or partial checkout."
        )
    return resolved_repo_root
