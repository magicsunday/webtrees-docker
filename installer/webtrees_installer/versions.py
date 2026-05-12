"""Load the bundled image catalog (versions.json + nginx + installer)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


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
    return _read_json(path)["tag"]


def _load_installer_version(path: Path) -> str:
    return _read_json(path)["version"]


def _read_json(path: Path) -> Any:
    """Read a JSON manifest, raising FileNotFoundError with the basename on miss."""
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    return json.loads(path.read_text())
