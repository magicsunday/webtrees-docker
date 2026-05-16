"""Lockstep guard for the nginx image tag.

The canonical nginx tag lives in `dev/nginx-version.json` (`.tag`).
Five sites repeat the tag literally — three test-side defaults plus
two operator-facing artefacts:

  * `Make/ci.mk` (the `ci-nginx-config` target's NGINX_IMAGE)
  * `tests/test-nginx-config.sh` (default for `TEST_NGINX_IMAGE`)
  * `tests/test-trust-proxy-extra.sh` (same default)
  * `templates/portainer/compose.yaml` (shipped Portainer stack)
  * `README.md` (operator pull instruction in prose)

Drift between any site and the canonical JSON pin is silently
survivable while a transitional multi-arch alias still resolves
the old tag, but fails loud with `manifest unknown` the moment
that alias is retired. This test fails any pre-merge bump that
leaves stragglers, so the gap cannot reappear.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

import pytest


# Symmetric with the Dockerfile / Make/ci.mk consumers: tag shape is
# `X.Y-rN` (semver-style major.minor + nginx-config revision suffix).
_TAG_RE = re.compile(
    r"webtrees-nginx:([0-9]+\.[0-9]+-r[0-9]+)"
)


def _resolve_repo_root() -> Path | None:
    """Mirror of test_mariadb_pin_lockstep's resolver — see that file
    for the precedence rationale."""
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


def _looks_like_repo_root(root: Path) -> bool:
    """Anchor-file check: a candidate path is a real repo root iff both
    `dev/versions.json` and `installer/pyproject.toml` exist underneath
    it. Symmetric with test_mariadb_pin_lockstep's guard."""
    return (root / "dev" / "versions.json").is_file() and (
        root / "installer" / "pyproject.toml"
    ).is_file()


_TAG_SITES = (
    "Make/ci.mk",
    "tests/test-nginx-config.sh",
    "tests/test-trust-proxy-extra.sh",
    "templates/portainer/compose.yaml",
    "README.md",
)


def test_nginx_tag_matches_canonical_across_all_sites() -> None:
    """Every test-side `webtrees-nginx:X.Y-rN` literal must agree with
    the `.tag` field of dev/nginx-version.json. The CI bump pipeline
    bumps the canonical JSON; this test catches stragglers."""
    root = _resolve_repo_root()
    if root is None or not _looks_like_repo_root(root):
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"resolve to a real repo root. Fix the bind-mount in "
                f"Make/ci.mk's ci-pytest target."
            )
        pytest.skip(
            f"repo root not reachable from {root} — running from an "
            f"installed wheel or partial checkout."
        )

    canonical = json.loads(
        (root / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )["tag"]

    drifted: dict[str, list[str]] = {}
    for relative in _TAG_SITES:
        path = root / relative
        if not path.is_file():
            pytest.fail(f"expected nginx-tag site missing: {relative}")
        found = sorted(set(_TAG_RE.findall(path.read_text(encoding="utf-8"))))
        if not found:
            pytest.fail(
                f"no `webtrees-nginx:X.Y-rN` literal in {relative}; "
                f"either the file no longer pins the image (update "
                f"_TAG_SITES) or the tag shape changed (update _TAG_RE)."
            )
        wrong = [tag for tag in found if tag != canonical]
        if wrong:
            drifted[relative] = wrong

    if drifted:
        rows = "\n  ".join(
            f"{site}: {tags!r} (canonical: {canonical!r})"
            for site, tags in drifted.items()
        )
        pytest.fail(
            f"nginx tag drift — every test-side literal must match "
            f"dev/nginx-version.json `.tag` = {canonical!r}:\n  {rows}"
        )


def test_tag_regex_extracts_expected_shape() -> None:
    """Positive control: the regex extracts the X.Y-rN portion from a
    realistic literal."""
    sample = '    NGINX_IMAGE="ghcr.io/magicsunday/webtrees-nginx:1.30-r1"'
    assert _TAG_RE.findall(sample) == ["1.30-r1"]


def test_tag_regex_ignores_unrelated_image_names() -> None:
    """Negative control: `magicsunday/webtrees-php-full:2.2.6-php8.5`
    must not match (different image name, not nginx)."""
    sample = "image: ghcr.io/magicsunday/webtrees-php-full:2.2.6-php8.5"
    assert _TAG_RE.findall(sample) == []
