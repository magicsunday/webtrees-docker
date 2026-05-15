"""Shared tristate-resolution helpers for CLI flags that flow into both
the standalone and dev flows.

The wizard pattern is "CLI flag wins outright; fall back to whatever an
existing `.env` carries; fall back to the wizard's default". Routing
every consumer through these helpers keeps the precedence policy in one
place — a new flag honouring the same tristate (cli / env / default)
picks up identical parse semantics without re-deriving them at the call
site.

Underscore prefix follows the existing convention (`_alpine`, `_docker`,
`_io`): module is implementation detail, not a public surface; callers
import the symbols they need rather than the module.
"""

from __future__ import annotations


def resolve_enforce_https(
    cli_value: bool | None,
    env_value: str | None,
    *,
    default: bool = True,
) -> bool:
    """Resolve the ENFORCE_HTTPS tristate to a concrete bool.

    Precedence (highest wins):
      1. ``cli_value`` — an explicit operator choice via the CLI flag
         (e.g. ``--no-https`` → False). Anything other than ``None``
         wins outright.
      2. ``env_value`` — the value carried by an existing ``.env`` on
         a re-render. Parsed case-insensitively against ``"TRUE"``.
      3. ``default`` — the wizard's fallback for a fresh install.

    Shared between the standalone and dev flows so the precedence stays
    a single source of truth — open-coding `.strip().upper() == "TRUE"`
    at every consumer would invite the kind of drift this helper exists
    to prevent.
    """
    if cli_value is not None:
        return cli_value
    if env_value is not None:
        return env_value.strip().upper() == "TRUE"
    return default
