"""Pre-render reachability probe for the external-db install path.

The probe runs once before the wizard renders compose.yaml — failing
fast at flag-parse time saves the operator from a 60 s container-up
attempt that ends in a phpfpm crash loop with a connection-refused
trace they have to read out of the logs. The TCP-connect handshake is
the cheapest meaningful check: it confirms the DNS / routing layer
plus the listener is accepting connections. It does NOT prove
credentials are correct — that gets checked once when phpfpm bootstraps
and surfaces (with the supplied user/db) at first request, in the
exact same shape it would for any misconfigured external DB.
"""

from __future__ import annotations

import socket

from webtrees_installer.prompts import PromptError


_DEFAULT_TIMEOUT_S = 5.0


def probe_external_db(
    *,
    host: str,
    port: int,
    timeout: float = _DEFAULT_TIMEOUT_S,
) -> None:
    """Refuse to render if the external DB host:port is unreachable.

    Raises PromptError with an operator-actionable single-line fix on
    DNS failure, connect timeout, or connection refused. Returns None
    on success.
    """
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return
    except socket.gaierror as exc:
        raise PromptError(
            f"External DB host {host!r} does not resolve: {exc}. "
            f"Fix DNS or pass --external-db-host with a resolvable name / IP."
        ) from exc
    except (TimeoutError, socket.timeout) as exc:
        raise PromptError(
            f"External DB {host}:{port} did not answer within {timeout:g}s. "
            f"Check that the listener is up and that no firewall sits in front."
        ) from exc
    except OSError as exc:
        raise PromptError(
            f"External DB {host}:{port} refused the connection: {exc}. "
            f"Verify the port, that the service is bound to a routable interface, "
            f"and that webtrees' client IP is allowed."
        ) from exc
