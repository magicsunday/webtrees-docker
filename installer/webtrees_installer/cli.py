"""Command-line entry point for webtrees-installer."""

from __future__ import annotations

import argparse
from typing import Sequence

from webtrees_installer import __version__


def build_parser() -> argparse.ArgumentParser:
    """Return the top-level argument parser."""
    parser = argparse.ArgumentParser(
        prog="webtrees-installer",
        description="Wizard for setting up a self-hosted webtrees stack.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"webtrees-installer {__version__}",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns the process exit code."""
    parser = build_parser()
    try:
        parser.parse_args(argv)
    except SystemExit as exc:
        # argparse raises SystemExit for --version / --help after printing;
        # surface the status as a return value so callers (and tests) can
        # observe it without the interpreter aborting.
        return int(exc.code or 0)
    return 0
