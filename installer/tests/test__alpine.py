"""Tests for ``_alpine.get_helper_image()``."""

from __future__ import annotations

import pytest

from webtrees_installer._alpine import ALPINE_BASE_IMAGE, get_helper_image


def test_get_helper_image_defaults_to_alpine_base_image(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without WEBTREES_HELPER_IMAGE set, returns the canonical alpine pin."""
    monkeypatch.delenv("WEBTREES_HELPER_IMAGE", raising=False)
    assert get_helper_image() == ALPINE_BASE_IMAGE


def test_get_helper_image_returns_override_when_env_is_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """WEBTREES_HELPER_IMAGE overrides the Docker Hub alpine reference."""
    monkeypatch.setenv("WEBTREES_HELPER_IMAGE", "ghcr.io/example/installer:1.2.3")
    assert get_helper_image() == "ghcr.io/example/installer:1.2.3"


def test_get_helper_image_ignores_whitespace_only_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A whitespace-only WEBTREES_HELPER_IMAGE falls back to the alpine pin."""
    monkeypatch.setenv("WEBTREES_HELPER_IMAGE", "   ")
    assert get_helper_image() == ALPINE_BASE_IMAGE
