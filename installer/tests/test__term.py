"""Unit tests for webtrees_installer._term."""

from __future__ import annotations

import io
import os
from typing import IO
from unittest import mock

import pytest

from webtrees_installer._term import Term, colour_supported


class _FakeTTY(io.StringIO):
    """StringIO that claims to be a TTY for `colour_supported` testing."""

    def isatty(self) -> bool:  # noqa: D401 — match IO contract
        return True


def _no_color_env() -> mock._patch[dict[str, str]]:
    """Strip NO_COLOR from the test env so tests see a clean baseline."""
    env = {k: v for k, v in os.environ.items() if k != "NO_COLOR"}
    return mock.patch.dict(os.environ, env, clear=True)


# ---------------------------------------------------------------------- support


def test_colour_supported_returns_false_when_stream_is_none() -> None:
    with _no_color_env():
        assert colour_supported(None) is False


def test_colour_supported_returns_false_when_stream_is_not_tty() -> None:
    # plain StringIO does not pretend to be a TTY.
    plain: IO[str] = io.StringIO()
    with _no_color_env():
        assert colour_supported(plain) is False


def test_colour_supported_returns_true_for_tty_without_no_color() -> None:
    tty: IO[str] = _FakeTTY()
    with _no_color_env():
        assert colour_supported(tty) is True


def test_colour_supported_returns_false_when_no_color_set() -> None:
    tty: IO[str] = _FakeTTY()
    with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
        assert colour_supported(tty) is False


def test_colour_supported_respects_empty_no_color_value() -> None:
    # Per https://no-color.org, presence of the key opts out regardless of value.
    tty: IO[str] = _FakeTTY()
    with mock.patch.dict(os.environ, {"NO_COLOR": ""}):
        assert colour_supported(tty) is False


def test_colour_supported_returns_false_when_isatty_raises() -> None:
    """A stream whose `isatty` raises (closed file) must opt out, not crash."""

    class _BrokenStream(io.StringIO):
        def isatty(self) -> bool:
            raise ValueError("I/O operation on closed file")

    with _no_color_env():
        assert colour_supported(_BrokenStream()) is False


# ---------------------------------------------------------------------- styling


def test_term_disabled_returns_plain_text_for_every_helper() -> None:
    term = Term(enabled=False)
    assert term.success("ok") == "ok"
    assert term.error("bad") == "bad"
    assert term.warning("hmm") == "hmm"
    assert term.info("fyi") == "fyi"
    assert term.bold("loud") == "loud"


def test_term_enabled_wraps_with_ansi_sequences_and_resets() -> None:
    term = Term(enabled=True)
    # Each helper wraps with a distinct colour code; all reset at the end.
    assert term.success("ok") == "\033[32mok\033[0m"
    assert term.error("bad") == "\033[31mbad\033[0m"
    assert term.warning("hmm") == "\033[33mhmm\033[0m"
    assert term.info("fyi") == "\033[36mfyi\033[0m"
    assert term.bold("loud") == "\033[1mloud\033[0m"


def test_term_for_stream_binds_to_stream_decision() -> None:
    plain: IO[str] = io.StringIO()
    tty: IO[str] = _FakeTTY()
    with _no_color_env():
        assert Term.for_stream(plain).enabled is False
        assert Term.for_stream(tty).enabled is True


@pytest.mark.parametrize(
    ("helper_name", "ansi_code"),
    [
        ("success", "\033[32m"),
        ("error",   "\033[31m"),
        ("warning", "\033[33m"),
        ("info",    "\033[36m"),
        ("bold",    "\033[1m"),
    ],
)
def test_term_ansi_codes_distinct(helper_name: str, ansi_code: str) -> None:
    """Each helper must emit its own ANSI prefix — no accidental swap."""
    rendered = getattr(Term(enabled=True), helper_name)("payload")
    assert rendered.startswith(ansi_code)
    assert rendered.endswith("\033[0m")
