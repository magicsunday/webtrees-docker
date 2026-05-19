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


def cli_optout_to_tristate(opt_out: bool) -> bool | None:
    """Map a `--no-X` opt-out CLI flag onto the wizard's tristate.

    Wizard tristates carry three states: ``True`` (explicit opt-in via
    `--X`), ``False`` (explicit opt-out via `--no-X`), or ``None``
    (operator passed neither; let the downstream resolver honour the
    .env value or apply the wizard default).

    argparse's ``store_true`` for `--no-X` cannot express the
    operator-said-nothing state on its own — a missing flag and an
    explicit absence both surface as ``False``. The two consumers
    (StandaloneArgs + DevArgs construction in cli.py) therefore have to
    translate `args.no_X` into the tristate themselves: ``False`` only
    when the operator passed `--no-X`, otherwise ``None``. Both sites
    were spelling out ``False if args.no_X else None`` inline; centralising
    here prevents the GH-147 → GH-148 mirror-bug pattern from recurring
    if a future `--no-Y` opt-out lands.
    """
    return False if opt_out else None


def resolve_enforce_https(
    cli_value: bool | None,
    env_value: str | None,
    *,
    proxy_mode: str,
) -> bool:
    """Resolve the ENFORCE_HTTPS tristate to a concrete bool.

    Precedence (highest wins):
      1. ``cli_value`` — an explicit operator choice via the CLI flag
         (e.g. ``--no-https`` → False). Anything other than ``None``
         wins outright.
      2. ``env_value`` — the value carried by an existing ``.env`` on
         a re-render. Parsed case-insensitively against ``"TRUE"``.
      3. Smart default keyed on ``proxy_mode``:
           * ``standalone`` → ``False``. No upstream TLS terminator is
             in scope; defaulting True would emit a 301 to
             ``https://<host>/`` that nothing answers (port 443
             unbound), trapping direct-LAN browsers in a broken
             redirect. Operators who terminate TLS in front of the
             standalone stack themselves (Caddy / nginx-on-host /
             Cloudflare Tunnel) pre-create an ``.env`` with
             ``ENFORCE_HTTPS=TRUE`` before running the wizard; the env
             value wins via branch 2 above.
           * ``traefik`` (and any non-standalone mode) → ``True``.
             Traefik terminates TLS upstream and forwards
             ``X-Forwarded-Proto=https``; in-app links must match the
             public scheme.

    Shared between the standalone and dev flows so both the precedence
    AND the smart default stay a single source of truth — duplicating
    the ``default = proxy_mode != "standalone"`` derivation at every
    call site invited exactly the drift that fix issue tracked between
    GH-147 (flow.py) and GH-148 (dev_flow.py). Callers pass the
    PROMPT-RESOLVED ``proxy_mode``, never the raw CLI arg, so the
    interactive path (operator picks "Standalone" at the
    ``ask_choice``/``use_traefik`` prompt) also lands at the right
    default.
    """
    if cli_value is not None:
        return cli_value
    if env_value is not None:
        return env_value.strip().upper() == "TRUE"
    return proxy_mode != "standalone"
