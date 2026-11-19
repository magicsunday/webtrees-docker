"""Lockstep guard for the MariaDB image pin.

The MariaDB tag `mariadb:X.Y` is hardcoded in four sibling files:

  * `installer/webtrees_installer/templates/compose.standalone.j2`
  * `installer/webtrees_installer/templates/compose.traefik.j2`
  * `compose.yaml` (the dev-stack compose)
  * `templates/portainer/compose.yaml`

The check-mariadb.yml cron workflow reads the standalone template as
the canonical source — it would silently miss a drift in any of the
other three. This test enforces that all four sites agree.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


# Pattern symmetric with the check-mariadb.yml workflow's
# `^\s*image:\s*mariadb:[0-9]+\.[0-9]+` grep — both must accept the same
# line shapes. The trailing portion is `(?:\s.*)?$` (not `\s*$`) so a
# YAML inline comment like `image: mariadb:11.8  # rolling-minor` is
# accepted by BOTH parsers; otherwise the workflow would parse a pin
# that the lockstep test reports as missing.
_PIN_RE = re.compile(
    r"^\s*image:\s*mariadb:([0-9]+\.[0-9]+)(?:\s.*)?$",
    re.MULTILINE,
)


_PIN_SITES = (
    "installer/webtrees_installer/templates/compose.standalone.j2",
    "installer/webtrees_installer/templates/compose.traefik.j2",
    "compose.yaml",
    "templates/portainer/compose.yaml",
)


def test_mariadb_pin_consistent_across_all_sites(
    validated_repo_root: Path,
) -> None:
    """Every shipped compose file that pins MariaDB must agree on the
    same X.Y minor. A drift would let the check-mariadb.yml cron silently
    track the wrong baseline."""
    root = validated_repo_root

    pins: dict[str, str] = {}
    for relative in _PIN_SITES:
        path = root / relative
        if not path.is_file():
            pytest.fail(f"expected pin site missing: {relative}")
        match = _PIN_RE.search(path.read_text(encoding="utf-8"))
        if not match:
            pytest.fail(
                f"no `image: mariadb:X.Y` directive in {relative}; "
                f"either the file no longer pins MariaDB (update _PIN_SITES) "
                f"or the line shape changed (update _PIN_RE)."
            )
        pins[relative] = match.group(1)

    unique = set(pins.values())
    if len(unique) > 1:
        rows = "\n  ".join(f"{site}: {ver}" for site, ver in pins.items())
        pytest.fail(
            f"MariaDB pin drift across compose sites — every line must "
            f"carry the same X.Y minor:\n  {rows}"
        )


def test_pin_regex_accepts_trailing_comment() -> None:
    """Symmetry guard with the workflow grep: a trailing YAML comment on
    the image line is a valid (if unusual) shape that both parsers must
    accept. Without this case the lockstep test would report a missing
    pin while the workflow scans against it."""
    sample = "        image: mariadb:11.9  # rolling-minor"
    match = _PIN_RE.search(sample)
    assert match is not None, "regex must accept trailing-comment image lines"
    assert match.group(1) == "11.9"


def test_pin_regex_rejects_comment_only_line() -> None:
    """A bare comment mentioning `mariadb:X.Y` (such as the BYOD
    section's prose explainer) MUST NOT match — `_PIN_RE` anchors on
    `image:` to keep prose mentions out of the lockstep scan."""
    sample = "        # a host path. mariadb:11.8 expects the directory empty"
    assert _PIN_RE.search(sample) is None


def test_pin_regex_accepts_bare_eol_image_line() -> None:
    """The canonical shape every shipped compose site uses today is
    `image: mariadb:11.8` with bare EOL (no trailing whitespace or
    comment). Pin it explicitly so a future refactor cannot silently
    lose coverage of the most common form."""
    sample = "        image: mariadb:11.8"
    match = _PIN_RE.search(sample)
    assert match is not None
    assert match.group(1) == "11.8"


def test_pin_regex_rejects_patch_pinned_x_y_z() -> None:
    """Pin policy: X.Y rolling-minor only. A `mariadb:11.9.3` literal
    would freeze on a specific patch while the workflow continues to
    treat the pin as `11.9` (after the workflow's sed strip). Both
    the workflow grep and this regex must REJECT the X.Y.Z shape so
    a contributor switching to a patch-pin gets a loud lockstep
    failure pointing at the policy violation."""
    sample = "        image: mariadb:11.9.3"
    assert _PIN_RE.search(sample) is None

