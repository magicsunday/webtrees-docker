"""Tests for the prompt library."""

from __future__ import annotations

from io import StringIO

import pytest

from webtrees_installer.prompts import (
    Choice,
    PromptError,
    ask_choice,
    ask_text,
    ask_yesno,
)


def test_ask_text_uses_default_on_empty_input() -> None:
    answer = ask_text(
        "Domain",
        default="webtrees.example.org",
        stdin=StringIO("\n"),
        stdout=StringIO(),
    )
    assert answer == "webtrees.example.org"


def test_ask_text_uses_input_when_provided() -> None:
    answer = ask_text(
        "Domain",
        default="webtrees.example.org",
        stdin=StringIO("foo.local\n"),
        stdout=StringIO(),
    )
    assert answer == "foo.local"


def test_ask_text_short_circuits_on_value() -> None:
    """`value` argument bypasses stdin entirely (non-interactive plumbing)."""
    answer = ask_text("Domain", default="x", value="from-flag", stdin=None, stdout=None)
    assert answer == "from-flag"


def test_ask_text_required_rejects_empty() -> None:
    """No default + empty input → PromptError."""
    with pytest.raises(PromptError, match="required"):
        ask_text(
            "Domain",
            default=None,
            stdin=StringIO("\n"),
            stdout=StringIO(),
        )


def test_ask_choice_returns_label_for_index_input() -> None:
    choices = [
        Choice("core", "Core (plain Webtrees)"),
        Choice("full", "Full (with Magic Sunday charts)"),
    ]
    answer = ask_choice(
        "Edition",
        choices=choices,
        default="full",
        stdin=StringIO("1\n"),
        stdout=StringIO(),
    )
    assert answer == "core"


def test_ask_choice_uses_default_on_empty_input() -> None:
    choices = [Choice("core", "Core"), Choice("full", "Full")]
    answer = ask_choice(
        "Edition",
        choices=choices,
        default="full",
        stdin=StringIO("\n"),
        stdout=StringIO(),
    )
    assert answer == "full"


def test_ask_choice_short_circuits_on_value() -> None:
    choices = [Choice("core", "Core"), Choice("full", "Full")]
    answer = ask_choice(
        "Edition",
        choices=choices,
        default="full",
        value="core",
        stdin=None,
        stdout=None,
    )
    assert answer == "core"


def test_ask_choice_rejects_unknown_value() -> None:
    choices = [Choice("core", "Core"), Choice("full", "Full")]
    with pytest.raises(PromptError, match="invalid"):
        ask_choice(
            "Edition", choices=choices, default="full", value="demo",
            stdin=None, stdout=None,
        )


def test_ask_choice_rejects_empty_choices() -> None:
    """An empty choices sequence fails fast instead of crashing in I/O."""
    with pytest.raises(PromptError, match="no choices provided"):
        ask_choice(
            "Edition", choices=[], default="full",
            stdin=None, stdout=None,
        )


def test_ask_yesno_default_yes_on_empty() -> None:
    assert ask_yesno(
        "Bootstrap?", default=True,
        stdin=StringIO("\n"), stdout=StringIO(),
    ) is True


def test_ask_yesno_default_no_on_empty() -> None:
    assert ask_yesno(
        "Bootstrap?", default=False,
        stdin=StringIO("\n"), stdout=StringIO(),
    ) is False


@pytest.mark.parametrize("inp,want", [("y", True), ("Y", True), ("yes", True),
                                       ("n", False), ("N", False), ("no", False)])
def test_ask_yesno_parses_explicit_answers(inp: str, want: bool) -> None:
    assert ask_yesno(
        "Bootstrap?", default=True,
        stdin=StringIO(f"{inp}\n"), stdout=StringIO(),
    ) is want
