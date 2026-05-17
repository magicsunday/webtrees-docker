#!/usr/bin/env python3
"""Rewrite the static webtrees + PHP badges in README.md.

Reads `dev/versions.json` (or another path passed as `--versions`),
extracts every unique `.webtrees` / `.php` string value, sorts in
natural numeric order (8.5 BEFORE 8.10; 2.1.27 BEFORE 2.2.6),
URL-encodes `|` as `%7C`, and rewrites both shields.io badge URLs
in `README.md`.

Invoked by `check-versions.yml` from inside the same workflow step
that bumps `dev/versions.json`, so the resulting auto-bump PR
commits both files atomically. The `ci-readme-badge-lockstep` is
membership-strict (every value in versions.json must appear in the
badge URL set) and runs on every PR via `ci-test.yml`, so a
catalog-only commit would fail the lockstep and block its own
auto-merge — coupling both edits into one commit closes that
cascade.

Idempotent: a no-op against an already-canonical README produces
identical output (same input → same substitution), so re-running
the rewriter against a fresh state from `git reset` is safe.

Natural sort: each value is split on `.`, segments are coerced to
`int` (or `0` for any non-numeric segment such as a pre-release
tag), and the segment tuple is the sort key. Examples:
  * `8.10` → `(8, 10)`, sorts after `8.5` → `(8, 5)`.
  * `2.1.27` → `(2, 1, 27)`, sorts before `2.2.6` → `(2, 2, 6)`.
  * `2.3.0-beta.1` → `(2, 3, 0, 1)` (segment `0-beta` is non-
    numeric and buckets at 0; `1` parses cleanly). Sorts after
    `2.3.0` → `(2, 3, 0)` because Python tuple comparison treats
    the longer tuple as greater when its prefix is equal.
  * `2.3.0-beta` → `(2, 3, 0)` (single non-numeric trailing
    segment). Ties with `2.3.0`; Python's stable sort preserves
    catalog insertion order between ties.

Hyphen-tolerant: `re.subn(... .+? ...)` accepts pre-release tags
in the existing badge message field. A naive
`sed s|webtrees-[^-]+-blue|...|` would silently no-op once a
hyphen lands in the message.

Backref-safe: the replacement is supplied as a callable, not a
formatted string. `re.subn` interprets `\\1`, `\\g<name>` etc. in
its replacement argument; a catalog value containing a backslash
+ digit would otherwise crash the rewriter with `re.error:
invalid group reference`.

Exits non-zero (with `::error::` annotation for GitHub Actions)
on either of two surfaces:
  * the catalog cannot be resolved (FileNotFoundError,
    json.JSONDecodeError, or ValueError — covers a missing file,
    malformed JSON, non-array top level, or an empty/whitespace-only
    .webtrees / .php field set);
  * either of the two badge regexes finds zero matches — that
    means the README badge URL shape changed and the rewriter
    needs updating.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


def _natural_sort_key(value: str) -> tuple[int, ...]:
    """Convert a dotted version string into a sortable tuple of ints.

    Non-numeric segments bucket at 0 so a pre-release tag like
    `2.3.0-beta.1` sorts adjacent to its release `2.3.0`. See the
    module docstring for worked examples.
    """
    parts: list[int] = []
    for segment in value.split("."):
        try:
            parts.append(int(segment))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def _extract_unique(catalog: list[object], field: str) -> list[str]:
    """Return the sorted-unique non-empty string values of `field`.

    Skips rows where the row itself is not a dict (e.g. a stray
    scalar from a botched JSON merge), or where the field is missing,
    not a string, an empty string, or whitespace-only. Values that
    pass the guard are stripped of surrounding whitespace before
    deduplication so a hand-edited `"8.3 "` (trailing space) cannot
    land in the badge URL as a literal space.
    """
    seen: set[str] = set()
    out: list[str] = []
    for row in catalog:
        if not isinstance(row, dict):
            continue
        value = row.get(field)
        if not isinstance(value, str):
            continue
        cleaned = value.strip()
        if not cleaned:
            continue
        if cleaned not in seen:
            seen.add(cleaned)
            out.append(cleaned)
    out.sort(key=_natural_sort_key)
    return out


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


def _resolve_from_catalog(versions_path: pathlib.Path) -> tuple[str, str]:
    """Read versions.json and return URL-encoded (wt, php) badge values."""
    raw = json.loads(versions_path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError(
            f"{versions_path} must contain a JSON array, got {type(raw).__name__}"
        )
    wt_values = _extract_unique(raw, "webtrees")
    php_values = _extract_unique(raw, "php")
    if not wt_values:
        raise ValueError(
            f"{versions_path} contains no non-empty .webtrees string values"
        )
    if not php_values:
        raise ValueError(
            f"{versions_path} contains no non-empty .php string values"
        )
    return "%7C".join(wt_values), "%7C".join(php_values)


def main() -> int:
    """Parse argv, rewrite README.md in place, and return a CLI exit code."""
    parser = argparse.ArgumentParser(
        description="Rewrite the README's webtrees + PHP shields.io badges.",
    )
    parser.add_argument(
        "--versions",
        type=pathlib.Path,
        default=pathlib.Path("dev/versions.json"),
        help="Path to versions.json (default: dev/versions.json).",
    )
    parser.add_argument(
        "--readme",
        type=pathlib.Path,
        default=pathlib.Path("README.md"),
        help="Path to README.md (default: README.md).",
    )
    args = parser.parse_args()

    try:
        wt, php = _resolve_from_catalog(args.versions)
    except (FileNotFoundError, ValueError, json.JSONDecodeError) as exc:
        # GitHub Actions workflow commands are line-based; a literal
        # newline in the exception message would truncate the
        # annotation. Encode embedded newlines as `%0A` so multi-line
        # exception detail renders correctly in the Actions UI.
        detail = f"{type(exc).__name__}: {exc}".replace("\n", "%0A")
        print(
            f"::error::cannot extract badge values from {args.versions}: {detail}",
            file=sys.stderr,
        )
        return 1

    # Symmetric error handling with the catalog read above: a missing
    # / unreadable / non-writable README must surface as a
    # `::error::cannot {read,write} README...` annotation rather
    # than an uncaught Python traceback. The companion shell script
    # check-readme-badges.sh adds the same kind of guard via
    # `[ -f README.md ]`; without this block the two halves of the
    # badge-sync pair would fail with different diagnostic shapes.
    try:
        text = args.readme.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError) as exc:
        detail = f"{type(exc).__name__}: {exc}".replace("\n", "%0A")
        print(
            f"::error::cannot read README at {args.readme}: {detail}",
            file=sys.stderr,
        )
        return 1

    text, n_wt, n_php = rewrite(text, wt, php)
    if n_wt == 0 or n_php == 0:
        print(
            f"::error::README badge rewrite no-op "
            f"(webtrees={n_wt} php={n_php}); check the URL shape",
            file=sys.stderr,
        )
        return 1

    try:
        args.readme.write_text(text, encoding="utf-8")
    except OSError as exc:
        detail = f"{type(exc).__name__}: {exc}".replace("\n", "%0A")
        print(
            f"::error::cannot write README at {args.readme}: {detail}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
