"""Random password generation for the admin reveal banner."""

from __future__ import annotations

import secrets


def generate_password(*, hex_chars: int = 24) -> str:
    """Return a hex string of ``hex_chars`` characters.

    Each hex char encodes 4 bits, so the default ``hex_chars=24`` yields 96
    bits of entropy. ``hex_chars`` must be a positive even integer because
    ``secrets.token_hex`` consumes a byte count.
    """
    if hex_chars <= 0 or hex_chars % 2 != 0:
        raise ValueError("hex_chars must be an even positive integer")
    return secrets.token_hex(hex_chars // 2)
