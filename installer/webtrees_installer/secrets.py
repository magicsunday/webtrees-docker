"""Random password generation for the admin reveal banner."""

from __future__ import annotations

import secrets


def generate_password(*, length: int = 24) -> str:
    """Return a hex string of `length` characters (length * 4 bits of entropy)."""
    if length <= 0 or length % 2 != 0:
        raise ValueError("length must be an even positive integer")
    return secrets.token_hex(length // 2)
