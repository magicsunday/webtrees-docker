"""Interactive prompt helpers with non-interactive overrides.

Stdin contract: an empty reply (``""``, also what a closed stdin yields on
``readline()``) is intentionally treated as "accept the default" for both
``ask_text`` and ``ask_choice``. A missing default raises ``PromptError``.
``ask_yesno`` likewise returns ``default`` on empty input. Callers that
need fail-fast behaviour without a TTY should pass the answer via the
``value`` kwarg, which short-circuits the prompt entirely.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import IO


class PromptError(ValueError):
    """Raised when prompt input is missing or unparseable.

    Inherits from ``ValueError`` (not ``RuntimeError`` like ``PrereqError``)
    because the failure mode is a malformed or missing user value rather
    than a broken runtime environment.
    """


@dataclass(frozen=True)
class Choice:
    """One option in a multiple-choice prompt."""

    value: str
    label: str


def ask_text(
    question: str,
    *,
    default: str | None,
    value: str | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> str:
    """Read a free-form string answer. `value` overrides the prompt entirely."""
    if value is not None:
        if not value:
            raise PromptError(f"{question}: required")
        return value

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    suffix = f" [{default}]" if default is not None else ""
    print(f"{question}{suffix}: ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip()

    if reply:
        return reply
    if default is not None:
        return default
    raise PromptError(f"{question}: required")


def ask_choice(
    question: str,
    *,
    choices: Sequence[Choice],
    default: str,
    value: str | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> str:
    """Read one selection from `choices` by 1-based index. Returns the value."""
    if not choices:
        raise PromptError(f"{question}: no choices provided")
    valid = {c.value for c in choices}
    if default not in valid:
        raise PromptError(f"default {default!r} is not in choices")

    if value is not None:
        if value not in valid:
            raise PromptError(f"{question}: invalid value {value!r}")
        return value

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    print(question, file=stdout)
    for i, choice in enumerate(choices, start=1):
        marker = " (default)" if choice.value == default else ""
        print(f"  {i}) {choice.label}{marker}", file=stdout)
    print("Choice: ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip()

    if not reply:
        return default
    try:
        idx = int(reply)
    except ValueError as exc:
        raise PromptError(f"{question}: not a number: {reply!r}") from exc
    if not 1 <= idx <= len(choices):
        raise PromptError(f"{question}: out of range: {idx}")
    return choices[idx - 1].value


def ask_yesno(
    question: str,
    *,
    default: bool,
    value: bool | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> bool:
    """Read a y/n answer. Empty input returns `default`."""
    if value is not None:
        return value

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    hint = "[Y/n]" if default else "[y/N]"
    print(f"{question} {hint}: ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip().lower()

    if not reply:
        return default
    if reply in {"y", "yes"}:
        return True
    if reply in {"n", "no"}:
        return False
    raise PromptError(f"{question}: unparseable answer {reply!r}")
