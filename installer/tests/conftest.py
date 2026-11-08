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
