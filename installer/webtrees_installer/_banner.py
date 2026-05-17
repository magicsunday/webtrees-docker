"""Shared post-install banner snippets.

Both ``flow._print_banner`` (production wizard) and
``dev_flow._print_dev_banner`` (dev wizard) emit the same SSL warning
when ``proxy_mode == 'standalone'`` and ``ENFORCE_HTTPS=TRUE``: nginx
in standalone mode has no ``listen 443 ssl`` block, the published port
is a plain-HTTP socket, ENFORCE_HTTPS 301-redirects HTTP to HTTPS, and
the redirected HTTPS hits a non-TLS socket — the browser aborts with
SSL_ERROR_RX_RECORD_TOO_LONG. Direct browser access is only possible
once a TLS-terminating reverse proxy sits in front. Issue #118 docs
the full failure chain.

Keeping the warning text in one place (rather than duplicating in both
flows) means a future wording change touches one file and the contract
tests (``test_print_*_standalone_enforce_https_shows_warning_no_url``)
pin the exact phrases consumers must keep emitting.
"""

from __future__ import annotations

from typing import IO

from webtrees_installer._term import Term


def print_standalone_enforce_https_warning(
    *,
    stdout: IO[str],
    term: Term,
    redirect_target: str,
    rerun_verb: str,
) -> None:
    """Emit the 3-line ``standalone + ENFORCE_HTTPS=TRUE`` warning.

    Args:
        stdout: open writable text stream; the caller already
            resolved ``Term.for_stream(stdout)`` for the same
            stream.
        term: the resolved Term (color/no-color decided by the
            caller, so the helper reuses it rather than re-checking
            isatty).
        redirect_target: the host:port or domain the reverse proxy
            forwards to. Rendered into the example "(typically
            https://your-host/ → reverse-proxy → ``http://<target>/``)".
            ``flow`` passes ``this-host:<app_port>``; ``dev_flow``
            passes the dev_domain literal.
        rerun_verb: the CLI verb the operator runs to re-invoke the
            relevant wizard ("installer" or "dev wizard").

    No URL line is emitted; the warning explicitly tells the operator
    direct browser access is broken in this configuration.
    """
    print(
        f"{term.warning('⚠')} Direct browser access not possible: "
        f"ENFORCE_HTTPS=TRUE with --proxy standalone requires a "
        f"TLS-terminating reverse proxy in front (Caddy, "
        f"nginx-on-host, Cloudflare tunnel, …).",
        file=stdout,
    )
    print(
        f"  Once that proxy is up, point browsers at it (typically "
        f"https://your-host/ → reverse-proxy → http://{redirect_target}/).",
        file=stdout,
    )
    print(
        f"  For plaintext-only local access (no proxy needed), "
        f"re-run the {rerun_verb} with --no-https.",
        file=stdout,
    )
