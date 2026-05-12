"""Load the bundled image catalog (versions.json + nginx + installer)."""

from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path


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
        for entry in self.php_entries:
            if "latest" in entry.tags:
                return entry
        return self.php_entries[0]


def load_catalog(manifest_dir: Path) -> Catalog:
    """Read the three JSON manifests from manifest_dir and build a Catalog."""
    php_entries = _load_php_entries(manifest_dir / "versions.json")
    nginx_tag = _load_nginx_tag(manifest_dir / "nginx-version.json")
    installer_version = _load_installer_version(
        manifest_dir / "installer-version.json"
    )
    return Catalog(
        php_entries=php_entries,
        nginx_tag=nginx_tag,
        installer_version=installer_version,
    )


def _load_php_entries(path: Path) -> tuple[PhpEntry, ...]:
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    rows: Iterable[dict] = json.loads(path.read_text())
    return tuple(
        PhpEntry(
            webtrees=row["webtrees"],
            php=row["php"],
            tags=tuple(row.get("tags", [])),
        )
        for row in rows
    )


def _load_nginx_tag(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    data = json.loads(path.read_text())
    return data["tag"]


def _load_installer_version(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    data = json.loads(path.read_text())
    return data["version"]
