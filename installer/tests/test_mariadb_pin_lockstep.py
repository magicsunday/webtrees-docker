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

import re
from pathlib import Path

import pytest


_PIN_RE = re.compile(r"^\s*image:\s*mariadb:([0-9]+\.[0-9]+)\s*$", re.MULTILINE)


def _repo_root() -> Path:
    """Resolve the repo root.

    Returns Path("") when the test file's `parents[2]` is not a real
    repo root (partial-mount CI container); callers gate on the
    marker-file check.
    """
    import os

    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    return Path(__file__).resolve().parents[2]


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
    root = _repo_root()
    if not _looks_like_repo_root(root):
        pytest.skip(
            f"repo root not reachable from {root} — running in a "
            f"partial-mount container; the full-tree run is authoritative."
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
