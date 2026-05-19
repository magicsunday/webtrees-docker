"""Tests for ``webtrees_installer._banner``.

The shared SSL-warning helper is consumed by both ``flow._print_banner``
and ``dev_flow._print_dev_banner``; the existing branch-level tests
(``test_print_banner_standalone_enforce_https_shows_warning_no_url`` in
``test_flow.py`` and the dev-flow mirror in ``test_dev_flow.py``)
exercise it through both callers. These tests pin the helper's own
contract directly so a future refactor of either caller cannot silently
drop the SSL-warning content as long as the helper itself stays
intact.
"""

from __future__ import annotations

from io import StringIO

import pytest

from webtrees_installer._banner import (
    print_standalone_enforce_https_warning,
    print_standalone_http_security_note,
    print_standalone_http_url_lines,
    print_what_next_section,
)
from webtrees_installer._term import Term


def test_print_standalone_enforce_https_warning_emits_three_lines() -> None:
    """The helper emits exactly three printed lines: warning headline,
    proxy-redirect example, and ``--no-https`` escape hatch."""
    out = StringIO()
    print_standalone_enforce_https_warning(
        stdout=out,
        term=Term.for_stream(out),
        redirect_target="this-host:50024",
        rerun_verb="installer",
    )
    lines = [line for line in out.getvalue().split("\n") if line]
    assert len(lines) == 3, (
        f"expected 3 emitted lines, got {len(lines)}: {lines!r}"
    )


def test_print_standalone_enforce_https_warning_no_misleading_https_url() -> None:
    """The helper MUST NOT emit a tempting ``https://<host>:<port>/``
    URL the operator would paste into a browser. Pins the
    issue #118 contract."""
    out = StringIO()
    print_standalone_enforce_https_warning(
        stdout=out,
        term=Term.for_stream(out),
        redirect_target="this-host:50024",
        rerun_verb="installer",
    )
    text = out.getvalue()
    assert "https://this-host:50024" not in text
    assert "https://localhost" not in text
    # The literal `https://your-host/` placeholder in the redirect
    # example IS allowed — it's not a copy-pasteable URL.


def test_print_standalone_enforce_https_warning_includes_required_phrases() -> None:
    """Every contract-key phrase appears in the emitted text. These
    phrases are also asserted by the two caller-side tests, so
    drift between helper + callers will surface in CI immediately."""
    out = StringIO()
    print_standalone_enforce_https_warning(
        stdout=out,
        term=Term.for_stream(out),
        redirect_target="this-host:50024",
        rerun_verb="installer",
    )
    text = out.getvalue()
    assert "Direct browser access not possible" in text
    assert "TLS-terminating reverse proxy" in text
    assert "--no-https" in text


def test_print_standalone_enforce_https_warning_interpolates_redirect_target() -> None:
    """The redirect_target arg is rendered into the example URL so
    the caller's value reaches the operator (this-host vs dev_domain
    distinguishes flow.py from dev_flow.py)."""
    out = StringIO()
    print_standalone_enforce_https_warning(
        stdout=out,
        term=Term.for_stream(out),
        redirect_target="webtrees.localhost:50010",
        rerun_verb="dev wizard",
    )
    text = out.getvalue()
    assert "http://webtrees.localhost:50010/" in text


def test_print_standalone_enforce_https_warning_interpolates_rerun_verb() -> None:
    """The rerun_verb arg is rendered into the --no-https hint so the
    operator gets the right CLI verb for the wizard they ran."""
    out = StringIO()
    print_standalone_enforce_https_warning(
        stdout=out,
        term=Term.for_stream(out),
        redirect_target="this-host:50024",
        rerun_verb="dev wizard",
    )
    assert "re-run the dev wizard with --no-https" in out.getvalue()


def test_print_standalone_http_security_note_emits_single_line() -> None:
    """The plaintext-HTTP advisory is one line — keeps banner real estate
    tight on the now-default standalone+ENFORCE_HTTPS=FALSE branch."""
    out = StringIO()
    print_standalone_http_security_note(
        stdout=out,
        term=Term.for_stream(out),
    )
    lines = [line for line in out.getvalue().splitlines() if line.strip()]
    assert len(lines) == 1


def test_print_standalone_http_security_note_includes_required_phrases() -> None:
    """Contract-key phrases pinning the plaintext-HTTP advisory.
    Symmetric counterpart to the ENFORCE_HTTPS=TRUE warning above.

    The opt-out instruction must reference the .env pre-seed
    mechanism (the actual way to force ENFORCE_HTTPS=TRUE on
    standalone — no `--https` argparse flag exists, only `--no-https`)
    so an operator following the banner advice doesn't hit
    `unrecognized arguments`."""
    out = StringIO()
    print_standalone_http_security_note(
        stdout=out,
        term=Term.for_stream(out),
    )
    text = out.getvalue()
    assert "HTTPS is off" in text
    assert "unencrypted" in text
    assert "ENFORCE_HTTPS=TRUE" in text


def test_print_standalone_http_url_lines_localhost_only_when_no_lan_ip() -> None:
    """When HOST_LAN_IP detection fails (host_lan_ip=None), the
    helper falls back to printing only the localhost URL — matching
    the wizard's pre-#117 behaviour so detection-failure is a clean
    no-op, not a regression."""
    out = StringIO()
    print_standalone_http_url_lines(
        stdout=out,
        term=Term.for_stream(out),
        app_port=50024,
        host_lan_ip=None,
    )
    text = out.getvalue()
    assert "http://localhost:50024/" in text
    assert text.count("Webtrees URL:") == 1, (
        "must print exactly one URL line when LAN IP is unavailable"
    )


def test_print_standalone_http_url_lines_empty_lan_ip_treated_as_none() -> None:
    """An empty-string host_lan_ip (detection ran but yielded
    nothing) behaves identically to None — no LAN line emitted."""
    out = StringIO()
    print_standalone_http_url_lines(
        stdout=out,
        term=Term.for_stream(out),
        app_port=50024,
        host_lan_ip="",
    )
    text = out.getvalue()
    assert "http://localhost:50024/" in text
    assert text.count("Webtrees URL:") == 1


def test_print_standalone_http_url_lines_emits_both_when_lan_ip_present() -> None:
    """With a detected LAN IP, the banner prints BOTH localhost AND
    the LAN IP so the operator sees the right URL whether they
    browse from the docker host or from a different machine. Pins
    issue #117's contract."""
    out = StringIO()
    print_standalone_http_url_lines(
        stdout=out,
        term=Term.for_stream(out),
        app_port=50024,
        host_lan_ip="192.168.178.25",
    )
    text = out.getvalue()
    assert "http://localhost:50024/" in text
    assert "http://192.168.178.25:50024/" in text
    assert text.count("Webtrees URL:") == 2, (
        "must print exactly two URL lines (localhost + LAN) when LAN IP is known"
    )


@pytest.mark.parametrize(
    "bad",
    [
        "evil.example.com",
        "2001:db8::1",
        "192.168.0.1 10.0.0.1",
        "\033[31m192.168.0.1",
        "999.999.999.999",
        "not-an-ip",
        " 192.168.0.1 ",
        "192.168.0.1\n",
        "192.168.0.1:8080",
    ],
    ids=[
        "hostname",
        "ipv6",
        "two-ips-one-string",
        "ansi-escape-prefix",
        "octet-overflow",
        "garbage",
        "whitespace-padded",
        "trailing-newline",
        "ip-with-port",
    ],
)
def test_print_standalone_http_url_lines_rejects_non_ipv4_host_lan_ip(bad: str) -> None:
    """Malformed host_lan_ip values fall back silently to the
    localhost-only line. Pins the Python-boundary shape re-validation
    so a future change that drops the bootstrap's awk regex (or a new
    detector path) cannot pollute the operator banner with junk.

    The helper does NOT strip whitespace — the documented call site
    in ``flow.py`` strips at the env-read boundary, so a future direct
    caller that forgets to strip lands cleanly in the fallback rather
    than emitting `http:// 192.168.0.1 :50024/`."""
    out = StringIO()
    print_standalone_http_url_lines(
        stdout=out,
        term=Term.for_stream(out),
        app_port=50024,
        host_lan_ip=bad,
    )
    text = out.getvalue()
    assert "http://localhost:50024/" in text
    assert text.count("Webtrees URL:") == 1


@pytest.mark.parametrize(
    "unreachable",
    [
        "127.0.0.1",        # loopback (operator-override-typo)
        "0.0.0.0",          # unspecified — Chrome ≥128 refuses, others ambiguous
        "169.254.1.1",      # link-local APIPA — requires same-subnet zeroconf
        "224.0.0.1",        # multicast
        "255.255.255.255",  # directed broadcast / reserved (240/4)
        "172.17.0.1",       # docker default-bridge gateway
        "100.64.5.1",       # CGNAT — provider NAT, not LAN-reachable
    ],
    ids=[
        "loopback",
        "unspecified",
        "link-local",
        "multicast",
        "broadcast",
        "docker-bridge",
        "cgnat",
    ],
)
def test_print_standalone_http_url_lines_rejects_unreachable_lan_ip_semantics(
    unreachable: str,
) -> None:
    """Syntactically-valid IPv4 addresses that can never reach a
    browser on another LAN machine fall back to the localhost-only
    line. The bash awk filter rejects these from auto-detected output,
    but the operator-override path (``HOST_LAN_IP=… ./install``)
    bypasses the whole detection branch — this re-validation is the
    only defence against an override like ``HOST_LAN_IP=127.0.0.1``."""
    out = StringIO()
    print_standalone_http_url_lines(
        stdout=out,
        term=Term.for_stream(out),
        app_port=50024,
        host_lan_ip=unreachable,
    )
    text = out.getvalue()
    assert "http://localhost:50024/" in text
    assert text.count("Webtrees URL:") == 1, (
        f"unreachable host_lan_ip {unreachable!r} should NOT emit a LAN URL line"
    )


def test_print_standalone_http_url_lines_labels_distinguish_localhost_vs_lan() -> None:
    """Each line carries a parenthetical disambiguator ('local to
    this host' vs 'LAN — browse from another machine') so the
    operator knows which URL to use depending on where their
    browser is. Pins the operator-facing copy."""
    out = StringIO()
    print_standalone_http_url_lines(
        stdout=out,
        term=Term.for_stream(out),
        app_port=8080,
        host_lan_ip="10.0.0.1",
    )
    text = out.getvalue()
    assert "(local to this host)" in text
    assert "(LAN" in text
    assert "another machine" in text


def test_print_what_next_section_emits_all_three_launcher_urls() -> None:
    """The re-entry guide (#119) must surface install / upgrade / switch
    so an operator who closed the terminal after a curl-pipe-bash
    install can find every re-entry point without going back to the
    README. A regression that renames the upstream repo, flips the
    main branch, or drops one of the three commands surfaces here."""
    out = StringIO()
    print_what_next_section(stdout=out, term=Term.for_stream(out))
    text = out.getvalue()
    base = "https://raw.githubusercontent.com/magicsunday/webtrees-docker/main"
    assert f"curl -fsSL {base}/install" in text
    assert f"curl -fsSL {base}/upgrade" in text
    assert f"curl -fsSL {base}/switch" in text
