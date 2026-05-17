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


def _lan_ip_is_browser_reachable(host_lan_ip: str | None) -> bool:
    """Validate shape + semantics of an operator-supplied or detected
    LAN IPv4 address. Returns True only when the address is a routable
    LAN IPv4 a browser on another machine could reach.

    The bash-side awk filter already enforces shape + the block-list
    on auto-detected output, but `HOST_LAN_IP=127.0.0.1 ./install`
    (operator override) bypasses detection — this is the ONLY defence
    against an override naming an address that can never reach a
    cross-machine browser.
    """
    if not host_lan_ip:
        return False
    try:
        addr = ipaddress.IPv4Address(host_lan_ip)
    except ipaddress.AddressValueError:
        return False
    return not (
        addr.is_loopback
        or addr.is_unspecified
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr in _DOCKER_BRIDGE_NET
        or addr in _CGNAT_NET
    )


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
    if _lan_ip_is_browser_reachable(host_lan_ip):
        print(
            f"{term.info('•')} Webtrees URL: http://{host_lan_ip}:{app_port}/ "
            f"(LAN — browse from another machine on the same network)",
            file=stdout,
        )


def print_standalone_http_url_lan_only(
    *,
    stdout: IO[str],
    term: Term,
    app_port: int,
    host_lan_ip: str | None,
) -> None:
    """Emit the LAN URL line ONLY (skips the localhost line).

    Used by the dev wizard (#138 parity), which already emits an
    operator-chosen ``http://{dev_domain}/`` URL — adding the LAN line
    gives developers SSHing into a remote dev VM a URL that resolves
    without an /etc/hosts edit. Empty / invalid / unreachable
    ``host_lan_ip`` is a silent no-op.
    """
    if _lan_ip_is_browser_reachable(host_lan_ip):
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


# Canonical upstream URLs the curl-pipe-bash launchers live behind.
# Centralised so a future repo rename (or branch flip) is one edit.
_REPO_RAW = "https://raw.githubusercontent.com/magicsunday/webtrees-docker/main"
_INSTALL_URL = f"{_REPO_RAW}/install"
_UPGRADE_URL = f"{_REPO_RAW}/upgrade"
_SWITCH_URL = f"{_REPO_RAW}/switch"


def print_what_next_section(
    *,
    stdout: IO[str],
    term: Term,
) -> None:
    """Emit the operator re-entry guide at the end of the banner.

    A `curl … | bash` install leaves no launcher script behind in the
    install dir — the bootstrap is piped from stdin and discarded.
    Three days later, an operator who wants to add an admin user, bump
    the webtrees image, or switch between core and full edition has no
    in-terminal signal for where the entry points live. This section
    prints the three canonical curl-pipe-bash commands so the banner
    is self-sufficient even after the operator closes their shell.

    Args:
        stdout: open writable text stream.
        term: the caller-resolved Term (color/no-color decided once
            at the call site).
    """
    print(file=stdout)
    print(
        f"{term.info('•')} To re-run the wizard "
        f"(preserves data; rewrites compose.yaml + .env):",
        file=stdout,
    )
    print(f"    curl -fsSL {_INSTALL_URL} | bash -s -- <flags>", file=stdout)
    print(
        f"{term.info('•')} To upgrade to a newer webtrees image "
        f"(drops the app volume, re-seeds source):",
        file=stdout,
    )
    print(f"    curl -fsSL {_UPGRADE_URL} | bash", file=stdout)
    print(
        f"{term.info('•')} To switch edition or proxy mode in-place:",
        file=stdout,
    )
    print(f"    curl -fsSL {_SWITCH_URL} | bash -s -- --edition core", file=stdout)
