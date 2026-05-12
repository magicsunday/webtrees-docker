"""Tests for the secrets helper."""

from webtrees_installer.secrets import generate_password


def test_generate_password_is_random() -> None:
    """Two consecutive calls produce distinct values."""
    assert generate_password() != generate_password()


def test_generate_password_length() -> None:
    """Default length is 24 hex chars = 96 bits of entropy."""
    assert len(generate_password()) == 24


def test_generate_password_custom_length() -> None:
    assert len(generate_password(hex_chars=32)) == 32
