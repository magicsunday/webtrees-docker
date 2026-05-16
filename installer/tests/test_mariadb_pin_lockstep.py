"""Lockstep guard for the MariaDB image pin.

The MariaDB tag `mariadb:X.Y` is hardcoded in three sibling files:

  * `installer/webtrees_installer/templates/compose.standalone.j2`
  * `installer/webtrees_installer/templates/compose.traefik.j2`
  * `compose.yaml` (the dev-stack compose)
  * `templates/portainer/compose.yaml`

The check-mariadb.yml cron workflow reads the standalone template as
the canonical source — it would silently miss a drift in any of the
other three. This test enforces that all four sites agree.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest


# Pattern symmetric with the check-mariadb.yml workflow's
# `^\s*image:\s*mariadb:[0-9]+\.[0-9]+` grep — both must accept the same
# line shapes. The trailing portion is `(?:\s.*)?$` (not `\s*$`) so a
# YAML inline comment like `image: mariadb:11.8  # rolling-minor` is
# accepted by BOTH parsers; otherwise the workflow would parse a pin
# that the lockstep test reports as missing.
_PIN_RE = re.compile(
    r"^\s*image:\s*mariadb:([0-9]+\.[0-9]+)(?:\s.*)?$",
    re.MULTILINE,
)


def _resolve_repo_root() -> Path | None:
    """Resolve the repo root.

    Precedence:
    1. ``WT_REPO_ROOT`` env var — set by Make/ci.mk's ci-pytest so the
       test can walk the full tree even though only ``installer/`` is
       the working dir.
    2. ``parents[2]`` of this file — works for host-shell pytest runs
       from inside the repo.

    Returns ``None`` when neither candidate exists (test file moved /
    `parents[2]` raises IndexError); the caller fails loud instead of
    silently skipping.
    """
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


_PIN_SITES = (
    "installer/webtrees_installer/templates/compose.standalone.j2",
    "installer/webtrees_installer/templates/compose.traefik.j2",
    "compose.yaml",
    "templates/portainer/compose.yaml",
)


def _looks_like_repo_root(root: Path) -> bool:
    return (root / "dev" / "versions.json").is_file() and (
        root / "installer" / "pyproject.toml"
    ).is_file()


def test_mariadb_pin_consistent_across_all_sites() -> None:
    """Every shipped compose file that pins MariaDB must agree on the
    same X.Y minor. A drift would let the check-mariadb.yml cron silently
    track the wrong baseline."""
    root = _resolve_repo_root()
    if root is None or not _looks_like_repo_root(root):
        # CI must set WT_REPO_ROOT to the bind-mounted full repo. Skip
        # only when running from outside a real repo (e.g. an installed
        # wheel's test-extras suite); fail loud inside CI where the env
        # var is the load-bearing wire — a silent skip there would let
        # mariadb-pin drift through unguarded.
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"resolve to a real repo root (missing dev/versions.json "
                f"or installer/pyproject.toml). Fix the bind-mount in "
                f"Make/ci.mk's ci-pytest target."
            )
        pytest.skip(
            f"repo root not reachable from {root} — running from an "
            f"installed wheel or partial checkout."
        )

    pins: dict[str, str] = {}
    for relative in _PIN_SITES:
        path = root / relative
        if not path.is_file():
            pytest.fail(f"expected pin site missing: {relative}")
        match = _PIN_RE.search(path.read_text())
        if not match:
            pytest.fail(
                f"no `image: mariadb:X.Y` directive in {relative}; "
                f"either the file no longer pins MariaDB (update _PIN_SITES) "
                f"or the line shape changed (update _PIN_RE)."
            )
        pins[relative] = match.group(1)

    unique = set(pins.values())
    if len(unique) > 1:
        rows = "\n  ".join(f"{site}: {ver}" for site, ver in pins.items())
        pytest.fail(
            f"MariaDB pin drift across compose sites — every line must "
            f"carry the same X.Y minor:\n  {rows}"
        )


def test_pin_regex_accepts_trailing_comment() -> None:
    """Symmetry guard with the workflow grep: a trailing YAML comment on
    the image line is a valid (if unusual) shape that both parsers must
    accept. Without this case the lockstep test would report a missing
    pin while the workflow scans against it."""
    sample = "        image: mariadb:11.9  # rolling-minor"
    match = _PIN_RE.search(sample)
    assert match is not None, "regex must accept trailing-comment image lines"
    assert match.group(1) == "11.9"


def test_pin_regex_rejects_comment_only_line() -> None:
    """A bare comment mentioning `mariadb:X.Y` (such as the BYOD
    section's prose explainer) MUST NOT match — that ambiguity was
    exactly the Round-1 finding."""
    sample = "        # a host path. mariadb:11.8 expects the directory empty"
    assert _PIN_RE.search(sample) is None
