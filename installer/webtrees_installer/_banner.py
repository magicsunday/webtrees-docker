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

import ipaddress
from typing import IO

from webtrees_installer._term import Term

# Networks the bash awk filter strips from `hostname -I` (install:123-134).
# Re-checked here because the operator-override path (`HOST_LAN_IP=… ./install`)
# bypasses the entire auto-detection branch — these networks reach the helper
# only via that override.
_DOCKER_BRIDGE_NET = ipaddress.IPv4Network("172.16.0.0/12")
_CGNAT_NET = ipaddress.IPv4Network("100.64.0.0/10")


def print_standalone_http_url_lines(
    *,
    stdout: IO[str],
    term: Term,
    app_port: int,
    host_lan_ip: str | None,
) -> None:
    """Emit the plaintext-HTTP browse URLs for standalone+ENFORCE_HTTPS=FALSE.

    Always prints the host-local URL (``http://localhost:<port>/``).
    When the host's primary LAN IPv4 was passed in (the ``install``
    bootstrap detects it on the host shell and exports it via the
    ``HOST_LAN_IP`` env var, since detection inside the installer
    container would return the docker-bridge IP), additionally
    prints the LAN URL on a second line so operators browsing from a
    different machine (WSL→NAS, SSH-into-server, remote dev VM) get
    a URL that resolves on the right host.

    Detection-failure falls back silently to the localhost-only
    behaviour the wizard had before issue #117.

    Args:
        stdout: open writable text stream.
        term: the caller-resolved Term (color/no-color decided once
            at the call site).
        app_port: the published nginx port from the wizard.
        host_lan_ip: the detected LAN IPv4 from the install
            bootstrap, or ``None``/empty when detection failed or
            the host has no usable LAN interface.
    """
    print(
        f"{term.info('•')} Webtrees URL: http://localhost:{app_port}/ "
        f"(local to this host)",
        file=stdout,
    )
    if not host_lan_ip:
        return
    # Validate twice: shape, then semantics. The install bootstrap's
    # awk filter already rejects non-IPv4 shapes and the bash-side
    # block-list (loopback, link-local, docker-bridge, CGNAT) on
    # auto-detected output — but `HOST_LAN_IP=127.0.0.1 ./install`
    # (operator override on bootstrap line 81) skips the whole
    # detection branch, so this is the ONLY defence against an
    # override that names an address which can never reach a browser
    # on another machine. Drop both shape junk (`evil.example.com`,
    # ANSI escapes, IPv6) AND unreachable semantics (loopback,
    # link-local, unspecified, broadcast, multicast, reserved, docker
    # bridge, CGNAT) silently — fall back to the localhost-only line
    # rather than printing a confidently-wrong "LAN" URL.
    try:
        addr = ipaddress.IPv4Address(host_lan_ip)
    except ipaddress.AddressValueError:
        return
    if (
        addr.is_loopback
        or addr.is_unspecified
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr in _DOCKER_BRIDGE_NET
        or addr in _CGNAT_NET
    ):
        return
    print(
        f"{term.info('•')} Webtrees URL: http://{host_lan_ip}:{app_port}/ "
        f"(LAN — browse from another machine on the same network)",
        file=stdout,
    )


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
