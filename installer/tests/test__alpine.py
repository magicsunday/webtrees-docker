"""Tests for the helper-image override on top of the Alpine pin.

The single-source-of-truth Alpine pin is itself covered by render.py and
the lockstep checks; this module locks down only the runtime override
that lets the smoke matrix (and end-user `install` script) re-use the
already-pulled installer image for short-lived helper operations and
sidestep Docker Hub's anonymous-pull quota.
"""

from __future__ import annotations

import pytest

from webtrees_installer._alpine import (
    ALPINE_BASE_IMAGE,
    HELPER_IMAGE_ENV_VAR,
    get_helper_image,
)


def test_default_returns_alpine_when_env_var_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    """No override → callers stay on the canonical Alpine pin."""
    monkeypatch.delenv(HELPER_IMAGE_ENV_VAR, raising=False)
    assert get_helper_image() == ALPINE_BASE_IMAGE


def test_override_returns_env_var_value(monkeypatch: pytest.MonkeyPatch) -> None:
    """A concrete override flows through verbatim."""
    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, "ghcr.io/magicsunday/webtrees-installer:1.0.0")
    assert get_helper_image() == "ghcr.io/magicsunday/webtrees-installer:1.0.0"


def test_whitespace_only_value_falls_back_to_alpine(monkeypatch: pytest.MonkeyPatch) -> None:
    """A value that strips to empty must not become the docker-run image
    (would produce a confusing `docker: invalid reference format`)."""
    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, "   \t  ")
    assert get_helper_image() == ALPINE_BASE_IMAGE


def test_empty_string_falls_back_to_alpine(monkeypatch: pytest.MonkeyPatch) -> None:
    """`export WEBTREES_HELPER_IMAGE=` is a common "unset" idiom in
    shell scripts; treat it the same as the var being missing."""
    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, "")
    assert get_helper_image() == ALPINE_BASE_IMAGE


def test_surrounding_whitespace_is_stripped(monkeypatch: pytest.MonkeyPatch) -> None:
    """Operators sometimes leave a trailing newline / space when
    composing the value in a YAML block scalar or shell heredoc; the
    resulting reference would be invalid without the trim."""
    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, "  ghcr.io/x/y:tag  \n")
    assert get_helper_image() == "ghcr.io/x/y:tag"


def test_resolution_happens_at_call_time(monkeypatch: pytest.MonkeyPatch) -> None:
    """A late `setenv` from a parent process (or a test fixture installed
    after module import) must be observed; binding the value at import
    time would silently shadow the override in long-lived processes."""
    monkeypatch.delenv(HELPER_IMAGE_ENV_VAR, raising=False)
    assert get_helper_image() == ALPINE_BASE_IMAGE

    monkeypatch.setenv(HELPER_IMAGE_ENV_VAR, "ghcr.io/late/binding:1")
    assert get_helper_image() == "ghcr.io/late/binding:1"
