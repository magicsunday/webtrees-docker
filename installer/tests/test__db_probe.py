"""Tests for the external-db reachability probe.

The probe gets called once at install time so the wizard refuses to
render a stack pointed at a DB it cannot reach. Each test exercises
one realistic failure mode (DNS, timeout, refused) plus the success
path, verifying that PromptError's message contains an
operator-actionable single-line fix the install banner can surface
verbatim.
"""

from __future__ import annotations

import socket
from unittest.mock import patch

import pytest

from webtrees_installer._db_probe import probe_external_db
from webtrees_installer.prompts import PromptError


class _FakeSocket:
    """Stub returned from a successful socket.create_connection patch."""

    def __enter__(self) -> _FakeSocket:
        return self

    def __exit__(self, *_: object) -> None:
        return None


def test_probe_returns_none_on_successful_connect() -> None:
    """Happy path: probe returns None without raising when the host accepts a TCP connect."""
    with patch("socket.create_connection", return_value=_FakeSocket()) as create:
        probe_external_db(host="db.internal", port=3306)
    create.assert_called_once_with(("db.internal", 3306), timeout=5.0)


def test_probe_passes_custom_timeout_through_to_socket() -> None:
    """The timeout kwarg flows into socket.create_connection unchanged."""
    with patch("socket.create_connection", return_value=_FakeSocket()) as create:
        probe_external_db(host="db.internal", port=3306, timeout=2.5)
    create.assert_called_once_with(("db.internal", 3306), timeout=2.5)


def test_probe_raises_prompt_error_on_dns_failure() -> None:
    """A gaierror surfaces as a PromptError that names DNS as the fix scope."""
    with patch(
        "socket.create_connection",
        side_effect=socket.gaierror("Name or service not known"),
    ):
        with pytest.raises(PromptError) as exc_info:
            probe_external_db(host="does-not-resolve.invalid", port=3306)
    message = str(exc_info.value)
    assert "does-not-resolve.invalid" in message
    assert "does not resolve" in message
    assert "--external-db-host" in message


def test_probe_raises_prompt_error_on_timeout() -> None:
    """A timeout surfaces as a PromptError that names firewall + listener as suspects."""
    with patch("socket.create_connection", side_effect=TimeoutError):
        with pytest.raises(PromptError) as exc_info:
            probe_external_db(host="db.internal", port=3306, timeout=2.0)
    message = str(exc_info.value)
    assert "did not answer" in message
    assert "2s" in message
    assert "firewall" in message


def test_probe_raises_prompt_error_on_connection_refused() -> None:
    """A connection-refused OSError surfaces as a PromptError with port + bind hints."""
    with patch(
        "socket.create_connection",
        side_effect=ConnectionRefusedError("[Errno 111] Connection refused"),
    ):
        with pytest.raises(PromptError) as exc_info:
            probe_external_db(host="db.internal", port=3306)
    message = str(exc_info.value)
    assert "refused" in message
    assert "port" in message.lower()


def test_probe_prompt_error_chains_original_exception() -> None:
    """The raised PromptError preserves the underlying socket exception via __cause__."""
    underlying = socket.gaierror("test failure")
    with patch("socket.create_connection", side_effect=underlying):
        with pytest.raises(PromptError) as exc_info:
            probe_external_db(host="x.invalid", port=3306)
    assert exc_info.value.__cause__ is underlying
