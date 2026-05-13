"""Load the bundled image catalog (versions.json + nginx + installer)."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_MANIFEST_DIR = Path("/opt/installer/versions")
"""Where the installer image bakes the catalog. Overridden by the
``WEBTREES_INSTALLER_MANIFEST_DIR`` env var when running tests or
out-of-image debugging."""


@dataclass(frozen=True)
class PhpEntry:
    """One row from versions.json: a webtrees release pinned to a PHP version."""

    webtrees: str
    php: str
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class Catalog:
    """Resolved tag catalog the wizard renders into compose templates."""

    php_entries: tuple[PhpEntry, ...]
    nginx_tag: str
    installer_version: str

    @property
    def default_php_entry(self) -> PhpEntry:
        """Return the entry tagged 'latest', or the first if none is tagged."""
        if not self.php_entries:
            raise ValueError("Catalog has no PHP entries")
        for entry in self.php_entries:
            if "latest" in entry.tags:
                return entry
        return self.php_entries[0]


def load_catalog(manifest_dir: Path) -> Catalog:
    """Read the three JSON manifests from manifest_dir and build a Catalog."""
    return Catalog(
        php_entries=_load_php_entries(manifest_dir / "versions.json"),
        nginx_tag=_load_nginx_tag(manifest_dir / "nginx-version.json"),
        installer_version=_load_installer_version(
            manifest_dir / "installer-version.json"
        ),
    )


def _load_php_entries(path: Path) -> tuple[PhpEntry, ...]:
    rows: list[dict[str, Any]] = _read_json(path)
    return tuple(
        PhpEntry(
            webtrees=row["webtrees"],
            php=row["php"],
            tags=tuple(row.get("tags", [])),
        )
        for row in rows
    )


def _load_nginx_tag(path: Path) -> str:
    tag: str = _read_json(path)["tag"]
    return tag


def _load_installer_version(path: Path) -> str:
    version: str = _read_json(path)["version"]
    return version


def _read_json(path: Path) -> Any:
    """Read a JSON manifest, raising FileNotFoundError with the basename on miss."""
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    return json.loads(path.read_text())


def resolve_manifest_dir() -> Path:
    """Locate the bundled image catalog at run-time.

    Prefers the ``WEBTREES_INSTALLER_MANIFEST_DIR`` env var (set by tests
    and by the build pipeline), else falls back to the in-image bake
    location. Raising here (instead of at import) keeps the failure mode
    in the flow layer where it can be translated into a clean CLI error
    instead of an opaque ImportError.
    """
    # PrereqError is imported lazily so versions.py stays free of cross-
    # module dependencies at import time (handy for `python -c "from
    # webtrees_installer.versions import load_catalog"` smoke tests).
    from webtrees_installer.prereq import PrereqError

    env_value = os.environ.get("WEBTREES_INSTALLER_MANIFEST_DIR")
    if env_value:
        return Path(env_value)
    if DEFAULT_MANIFEST_DIR.is_dir():
        return DEFAULT_MANIFEST_DIR
    raise PrereqError(
        "WEBTREES_INSTALLER_MANIFEST_DIR is not set and the bundled image "
        f"manifest directory {DEFAULT_MANIFEST_DIR} is missing. Are you "
        "running the wizard outside the installer image?"
    )
