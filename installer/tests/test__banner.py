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

from webtrees_installer._banner import print_standalone_enforce_https_warning
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
