#!/usr/bin/env python3
"""Rewrite the static webtrees + PHP badges in README.md.

Called by .github/workflows/check-versions.yml after each upstream-
release auto-bump appends new rows to dev/versions.json. The badge
URLs must mirror the unique values across all rows or the
ci-readme-badge-lockstep check fails on the auto-bump PR and
blocks auto-merge.

The rewriter lives in its own file (instead of being inlined in the
workflow YAML) so the Python body cannot inherit YAML indentation
and is unit-testable in isolation.

Hyphen-tolerant: `re.subn(... .+? ...)` accepts pre-release tags
in the message field (`2.3.0-beta.1` etc.). A naive
`sed s|webtrees-[^-]+-blue|...|` would silently no-op once a
hyphen lands in the message — the static-badge URL message field
admits arbitrary printable characters per shields.io's grammar.

Backref-safe: the replacement is supplied as a callable, not a
formatted string. `re.subn` interprets `\\1`, `\\g<name>` etc. in
its replacement argument; a future versions.json value containing
a backslash + digit would otherwise crash the rewriter with
`re.error: invalid group reference`.

Exits non-zero (with `::error::` annotation for GitHub Actions)
when either regex finds zero matches — that means the README
badge URL shape changed and the rewriter needs updating.
"""

from __future__ import annotations

import pathlib
import re
import sys


def rewrite(text: str, wt: str, php: str) -> tuple[str, int, int]:
    """Apply the two badge substitutions; return (text, n_wt, n_php)."""
    text, n_wt = re.subn(
        r"img\.shields\.io/badge/webtrees-.+?-blue",
        lambda _m: f"img.shields.io/badge/webtrees-{wt}-blue",
        text,
    )
    text, n_php = re.subn(
        r"img\.shields\.io/badge/PHP-.+?-787CB5",
        lambda _m: f"img.shields.io/badge/PHP-{php}-787CB5",
        text,
    )
    return text, n_wt, n_php


def main() -> int:
    """Parse argv, rewrite README.md in place, and return a CLI exit code."""
    if len(sys.argv) != 3:
        print(
            f"usage: {sys.argv[0]} <wt_encoded> <php_encoded>",
            file=sys.stderr,
        )
        return 2
    wt, php = sys.argv[1], sys.argv[2]
    readme = pathlib.Path("README.md")
    text = readme.read_text(encoding="utf-8")
    text, n_wt, n_php = rewrite(text, wt, php)
    if n_wt == 0 or n_php == 0:
        print(
            f"::error::README badge rewrite no-op "
            f"(webtrees={n_wt} php={n_php}); check the URL shape",
            file=sys.stderr,
        )
        return 1
    readme.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
