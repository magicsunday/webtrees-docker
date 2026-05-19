"""Direct unit tests for the tristate-resolution helpers.

The helpers also flow through end-to-end flow tests (test_flow.py +
test_dev_flow.py), but those exercise the full wizard path and are
slower; this file pins the precedence semantics with focused single-case
asserts so a regression on the resolver itself is easy to localise.
"""

from __future__ import annotations

import pytest

from webtrees_installer._cli_resolve import (
    cli_optout_to_tristate,
    resolve_enforce_https,
)


def test_cli_optout_to_tristate_opt_out_true_maps_to_false() -> None:
    """Explicit `--no-X` (opt_out=True) maps to False — the downstream
    resolver treats this as the operator's outright opt-out and refuses
    to honour the .env or smart-default fallbacks."""
    assert cli_optout_to_tristate(True) is False


def test_cli_optout_to_tristate_opt_out_false_maps_to_none() -> None:
    """Absent `--no-X` (opt_out=False) maps to None — the downstream
    resolver then honours the .env value or applies the wizard's
    smart default. This is the central reason for the helper: the
    inline `False if args.no_X else None` re-spelled at two
    StandaloneArgs / DevArgs construction sites was the GH-147 →
    GH-148 mirror-bug pattern in miniature."""
    assert cli_optout_to_tristate(False) is None


@pytest.mark.parametrize("cli_value", [True, False])
def test_resolve_enforce_https_cli_value_wins_outright(cli_value: bool) -> None:
    """Explicit CLI flag wins over every other source, including a
    contradicting .env and a contradicting proxy_mode smart default."""
    assert resolve_enforce_https(
        cli_value=cli_value,
        env_value="TRUE" if not cli_value else "FALSE",
        # contradicting smart default — cli must still win:
        proxy_mode="standalone" if cli_value else "traefik",
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
    False — matches the runtime entrypoint's parse policy.

    proxy_mode here would otherwise force the result; the env-value
    branch must short-circuit *before* the smart default kicks in."""
    assert resolve_enforce_https(
        cli_value=None, env_value=env_value, proxy_mode="traefik",
    ) is expected


def test_resolve_enforce_https_standalone_smart_default_is_false() -> None:
    """No CLI, no .env, `proxy_mode=standalone` → FALSE. Direct-LAN
    installs have no upstream TLS terminator; defaulting TRUE would
    emit a 301 to https://<host>/ that nothing answers (GH-147)."""
    assert resolve_enforce_https(
        cli_value=None, env_value=None, proxy_mode="standalone",
    ) is False


def test_resolve_enforce_https_traefik_smart_default_is_true() -> None:
    """No CLI, no .env, `proxy_mode=traefik` → TRUE. Traefik terminates
    TLS upstream and forwards X-Forwarded-Proto=https; in-app links
    must match the public scheme."""
    assert resolve_enforce_https(
        cli_value=None, env_value=None, proxy_mode="traefik",
    ) is True


def test_resolve_enforce_https_env_true_on_standalone_overrides_smart_default() -> None:
    """An operator who terminates TLS in front of the standalone stack
    themselves (Caddy / nginx-on-host / Cloudflare Tunnel) pre-creates
    an .env with ENFORCE_HTTPS=TRUE. That env value must win over the
    standalone-defaults-to-FALSE smart default, otherwise a re-render
    would silently downgrade the operator's deliberate HTTPS posture.
    Pins the env-vs-smart-default precedence for the standalone path
    specifically — the helper's docstring lists env > default but the
    case-insensitive parametrize above only exercises env-vs-TRUE-
    default (proxy_mode=traefik), leaving env-vs-FALSE-default
    (proxy_mode=standalone, this case) as the missing coverage."""
    assert resolve_enforce_https(
        cli_value=None, env_value="TRUE", proxy_mode="standalone",
    ) is True
