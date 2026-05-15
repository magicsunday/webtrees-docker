"""Direct unit tests for the tristate-resolution helpers.

The helpers also flow through end-to-end flow tests (test_flow.py +
test_dev_flow.py), but those exercise the full wizard path and are
slower; this file pins the precedence semantics with focused single-case
asserts so a regression on the resolver itself is easy to localise.
"""

from __future__ import annotations

import pytest

from webtrees_installer._cli_resolve import resolve_enforce_https


@pytest.mark.parametrize("cli_value", [True, False])
def test_resolve_enforce_https_cli_value_wins_outright(cli_value: bool) -> None:
    """Explicit CLI flag wins over every other source, including a
    contradicting .env and the wizard default."""
    assert resolve_enforce_https(
        cli_value=cli_value,
        env_value="TRUE" if not cli_value else "FALSE",
        default=not cli_value,
    ) is cli_value


@pytest.mark.parametrize(
    "env_value,expected",
    [
        ("TRUE", True),
        ("true", True),
        ("  True  ", True),
        ("FALSE", False),
        ("false", False),
        ("anything-else", False),
        ("", False),
    ],
)
def test_resolve_enforce_https_env_parsed_case_insensitive(
    env_value: str, expected: bool,
) -> None:
    """With no CLI override, an existing .env's ENFORCE_HTTPS value drives
    the result. Anything other than case-insensitive 'TRUE' resolves to
    False — matches the runtime entrypoint's parse policy."""
    assert resolve_enforce_https(
        cli_value=None, env_value=env_value, default=True,
    ) is expected


def test_resolve_enforce_https_fallback_to_default_when_both_missing() -> None:
    """No CLI, no .env → wizard default applies. Default-arg-of-True
    matches the wizard's current fresh-install posture (HTTPS on)."""
    assert resolve_enforce_https(cli_value=None, env_value=None) is True


def test_resolve_enforce_https_fallback_default_is_configurable() -> None:
    """The ``default`` kwarg lets a future caller swap the wizard's
    fallback policy without rewriting the resolver."""
    assert resolve_enforce_https(
        cli_value=None, env_value=None, default=False,
    ) is False
