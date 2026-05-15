"""Terminal styling helpers — ANSI colours with NO_COLOR + non-TTY fallback.

ANSI sequences are emitted only when the target stream is an attached TTY
and the operator has not set the NO_COLOR env var (the de-facto opt-out
standard, https://no-color.org). CI logs and piped output thus stay
plain ASCII, which keeps GitHub Actions / Docker logs readable.

Call `Term.for_stream(s)` once at the start of a render to capture the
isatty + NO_COLOR decision, then use the bound `success`, `warning`,
`error`, `info`, `bold` methods to wrap individual tokens. The Term
instance is a frozen dataclass — safe to pass around or store.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import IO


_RESET = "\033[0m"
_BOLD = "\033[1m"
_GREEN = "\033[32m"
_RED = "\033[31m"
_YELLOW = "\033[33m"
_CYAN = "\033[36m"


def colour_supported(stream: IO[str] | None) -> bool:
    """Return True when ANSI styling should be applied to *stream*.

    Suppressed when:
      * stream is None
      * NO_COLOR is set to any value (even empty) — the spec is explicit
        that presence-of-key is the trigger, value is irrelevant
      * stream is not a TTY (pipes / file redirects / CI logs)
    """
    if stream is None:
        return False
    if "NO_COLOR" in os.environ:
        return False
    try:
        return bool(stream.isatty())
    except (AttributeError, ValueError):
        return False


@dataclass(frozen=True)
class Term:
    """Bound styling decision for a specific stream.

    Capture once at render entry instead of re-probing isatty / env for
    every wrapped token; the values are also easier to mock in tests
    (`Term(enabled=True)` vs. `Term(enabled=False)`).
    """

    enabled: bool

    @classmethod
    def for_stream(cls, stream: IO[str] | None) -> "Term":
        return cls(enabled=colour_supported(stream))

    def _wrap(self, code: str, text: str) -> str:
        if not self.enabled:
            return text
        return f"{code}{text}{_RESET}"

    def success(self, text: str) -> str:
        return self._wrap(_GREEN, text)

    def error(self, text: str) -> str:
        return self._wrap(_RED, text)

    def warning(self, text: str) -> str:
        return self._wrap(_YELLOW, text)

    def info(self, text: str) -> str:
        return self._wrap(_CYAN, text)

    def bold(self, text: str) -> str:
        return self._wrap(_BOLD, text)
