#!/usr/bin/env python3
"""Bump the MariaDB image pin across all four shipped compose sites.

Used to action a `check-mariadb.yml` tracking issue (or any operator-
driven MariaDB minor bump). The lockstep test
`test_mariadb_pin_lockstep` is the safety net that catches drift if
a future site is added but this script is not updated.

Behaviour:
  1. Read the canonical (standalone template) to learn the current pin.
  2. Refuse if the new minor equals the current minor.
  3. sed-replace every `mariadb:<OLD>` literal in the four mirror sites
     enforced by `test_mariadb_pin_lockstep._PIN_SITES`.
  4. Print a next-steps reminder.

Exit codes:
  0 — bump applied; mirrors in sync.
  1 — input validation failed.
  2 — usage error.
"""

from __future__ import annotations

import pathlib
import re
import sys

_CANONICAL = pathlib.Path(
    "installer/webtrees_installer/templates/compose.standalone.j2"
)

_PIN_SITES: tuple[str, ...] = (
    "installer/webtrees_installer/templates/compose.standalone.j2",
    "installer/webtrees_installer/templates/compose.traefik.j2",
    "compose.yaml",
    "templates/portainer/compose.yaml",
)

_MINOR_RE = re.compile(r"^[0-9]+\.[0-9]+$")
_PIN_LINE_RE = re.compile(
    r"^\s*image:\s*mariadb:([0-9]+\.[0-9]+)(?:\s.*)?$",
    re.MULTILINE,
)


def _read_current_pin(root: pathlib.Path) -> str | None:
    """Return the currently pinned MariaDB minor, or None if not found."""
    canonical = root / _CANONICAL
    if not canonical.is_file():
        return None
    match = _PIN_LINE_RE.search(canonical.read_text(encoding="utf-8"))
    return match.group(1) if match else None


def _replace_in_mirror(path: pathlib.Path, old_minor: str, new_minor: str) -> int:
    """Replace every `mariadb:OLD` literal with `mariadb:NEW`.

    Returns the number of substitutions made. The regex requires an
    `image:` anchor to avoid touching prose mentions of MariaDB in
    documentation comments.
    """
    text = path.read_text(encoding="utf-8")
    new_text, n = re.subn(
        rf"(?m)^(\s*image:\s*mariadb:){re.escape(old_minor)}(\s.*)?$",
        rf"\g<1>{new_minor}\g<2>",
        text,
    )
    if n > 0:
        path.write_text(new_text, encoding="utf-8")
    return n


def bump(root: pathlib.Path, new_minor: str) -> int:
    """Apply the bump under `root`; return a CLI exit code."""
    if not _MINOR_RE.fullmatch(new_minor):
        print(
            f"::error::new minor {new_minor!r} must match X.Y "
            f"(e.g. '11.9'); patch-pins like 11.9.3 are policy-rejected",
            file=sys.stderr,
        )
        return 1

    current_minor = _read_current_pin(root)
    if current_minor is None:
        print(
            f"::error::canonical pin not found in {_CANONICAL}; "
            f"the file must carry an `image: mariadb:X.Y` directive",
            file=sys.stderr,
        )
        return 1

    if new_minor == current_minor:
        print(
            f"::error::pin already at mariadb:{current_minor}; "
            f"supply a different minor",
            file=sys.stderr,
        )
        return 1

    drift: list[str] = []
    for relative in _PIN_SITES:
        mirror = root / relative
        if not mirror.is_file():
            drift.append(f"missing: {relative}")
            continue
        hits = _replace_in_mirror(mirror, current_minor, new_minor)
        if hits == 0:
            drift.append(f"no `image: mariadb:{current_minor}` literal in {relative}")

    if drift:
        print("::error::mirror sync failed:", file=sys.stderr)
        for row in drift:
            print(f"  - {row}", file=sys.stderr)
        print(
            "Fix the mirrors manually. Run `make ci-pytest` to see the "
            "exact drift the lockstep test reports.",
            file=sys.stderr,
        )
        return 1

    print(f"Bumped MariaDB pin {current_minor} -> {new_minor}")
    for relative in _PIN_SITES:
        print(f"  mirror: {relative}")
    print()
    print("Next steps:")
    print(f"  1. Review release notes for MariaDB {new_minor}.")
    print("  2. Verify the upgrade path (test on a snapshot; major-minor "
          "moves may need `mariadb-upgrade`).")
    print("  3. Run `make ci-pytest ci-lockstep-tests`.")
    print("  4. Open a PR; CI re-runs the smoke matrix against the new pin.")
    return 0


def main() -> int:
    """Parse argv, dispatch the bump, return a CLI exit code."""
    argv = sys.argv[1:]
    if len(argv) != 1:
        print(
            f"usage: {sys.argv[0]} <new-minor>\n"
            f"  e.g. {sys.argv[0]} 11.9",
            file=sys.stderr,
        )
        return 2
    return bump(pathlib.Path.cwd(), argv[0])


if __name__ == "__main__":
    sys.exit(main())
