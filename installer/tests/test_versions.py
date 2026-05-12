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
        "nginx_base": "1.28",
        "config_revision": 1,
        "tag": "1.28-r1",
    }))
    (tmp_path / "installer-version.json").write_text(json.dumps({
        "version": "0.1.0",
        "tag": "0.1.0",
    }))

    catalog = load_catalog(tmp_path)

    assert isinstance(catalog, Catalog)
    assert catalog.default_php_entry.webtrees == "2.2.6"
    assert catalog.default_php_entry.php == "8.5"
    assert catalog.nginx_tag == "1.28-r1"
    assert catalog.installer_version == "0.1.0"


def test_default_php_entry_prefers_latest_tag(tmp_path: Path) -> None:
    """Entry tagged 'latest' wins regardless of position in the array."""
    (tmp_path / "versions.json").write_text(json.dumps([
        {"webtrees": "2.2.5", "php": "8.4"},
        {"webtrees": "2.2.6", "php": "8.5", "tags": ["latest"]},
    ]))
    (tmp_path / "nginx-version.json").write_text(json.dumps({
        "nginx_base": "1.28", "config_revision": 1, "tag": "1.28-r1",
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
