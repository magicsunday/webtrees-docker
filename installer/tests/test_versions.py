"""Tests for the versions loader."""

import json
from pathlib import Path

import pytest

from webtrees_installer.versions import Catalog, load_catalog


def test_load_catalog_reads_all_three_manifests(tmp_path: Path) -> None:
    """load_catalog() merges the three manifest files into a Catalog object."""
    (tmp_path / "versions.json").write_text(json.dumps([
        {"webtrees": "2.2.6", "php": "8.5", "tags": ["latest"]},
        {"webtrees": "2.2.6", "php": "8.4"},
    ]))
    (tmp_path / "nginx-version.json").write_text(json.dumps({
        "nginx_base": "1.30",
        "config_revision": 1,
        "tag": "1.30-r1",
    }))
    (tmp_path / "installer-version.json").write_text(json.dumps({
        "version": "0.1.0",
        "tag": "0.1.0",
    }))

    catalog = load_catalog(tmp_path)

    assert isinstance(catalog, Catalog)
    assert catalog.default_php_entry.webtrees == "2.2.6"
    assert catalog.default_php_entry.php == "8.5"
    assert catalog.nginx_tag == "1.30-r1"
    assert catalog.installer_version == "0.1.0"


def test_default_php_entry_prefers_latest_tag(tmp_path: Path) -> None:
    """Entry tagged 'latest' wins regardless of position in the array."""
    (tmp_path / "versions.json").write_text(json.dumps([
        {"webtrees": "2.2.5", "php": "8.4"},
        {"webtrees": "2.2.6", "php": "8.5", "tags": ["latest"]},
    ]))
    (tmp_path / "nginx-version.json").write_text(json.dumps({
        "nginx_base": "1.30", "config_revision": 1, "tag": "1.30-r1",
    }))
    (tmp_path / "installer-version.json").write_text(json.dumps({
        "version": "0.1.0", "tag": "0.1.0",
    }))

    catalog = load_catalog(tmp_path)

    assert catalog.default_php_entry.webtrees == "2.2.6"


def test_load_catalog_raises_on_missing_manifest(tmp_path: Path) -> None:
    """Missing versions.json raises FileNotFoundError with a clear message."""
    with pytest.raises(FileNotFoundError, match="versions.json"):
        load_catalog(tmp_path)


def test_default_php_entry_falls_back_to_first_without_latest_tag(tmp_path: Path) -> None:
    """No entry tagged 'latest' → default_php_entry returns php_entries[0]."""
    (tmp_path / "versions.json").write_text(json.dumps([
        {"webtrees": "2.2.4", "php": "8.3"},
        {"webtrees": "2.2.5", "php": "8.4"},
    ]))
    (tmp_path / "nginx-version.json").write_text(json.dumps({
        "nginx_base": "1.30", "config_revision": 1, "tag": "1.30-r1",
    }))
    (tmp_path / "installer-version.json").write_text(json.dumps({
        "version": "0.1.0", "tag": "0.1.0",
    }))

    catalog = load_catalog(tmp_path)

    assert catalog.default_php_entry.webtrees == "2.2.4"
    assert catalog.default_php_entry.php == "8.3"


def test_default_php_entry_raises_when_no_entries() -> None:
    """An empty catalog surfaces a clear error instead of IndexError."""
    catalog = Catalog(php_entries=(), nginx_tag="1.30-r1", installer_version="0.1.0")
    with pytest.raises(ValueError, match="no PHP entries"):
        catalog.default_php_entry
