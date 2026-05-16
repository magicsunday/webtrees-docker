"""Regression tests for the Make-parse-time shell-injection guard.

`Make/maintenance.mk` validates VERSION / CONFIG_REVISION at Make-parse
time via `$(value VAR)` + an inline `$(findstring …)` whitelist. The
guard rejects every pure-shell metacharacter: backtick, semicolon,
pipe, ampersand, redirect, quote, escape.

These tests pin the contract for each rejected character. A future
edit that drops a character from the whitelist, replaces `$(value
VERSION)` with `$(VERSION)`, or otherwise weakens the guard fails
the build the moment it lands.

Out of scope — `$(shell …)` / `:=` / `::=` / `!=` / `CURDIR=` command-
line overrides cannot be defeated from inside any Makefile under
GNU Make 4.4+ because Make itself evaluates these constructs at
command-line-assignment time, before any in-Makefile directive can
run. Operators receiving a `make bump-…` invocation from an untrusted
source should use the equivalent `./scripts/bump-*.sh` form, which
bypasses Make's parser entirely. The Make-side guard's value is
closing the common-typo class of shell-metacharacter mistakes on
the convenience-wrapper entry point, not the deliberate-hostile-
payload class.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest


def _resolve_repo_root() -> Path | None:
    """Resolve the repo root using the WT_REPO_ROOT precedence pattern."""
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


def _make_available(root: Path) -> bool:
    """True iff `make` is on PATH and the maintenance.mk recipe loads."""
    return (root / "Make" / "maintenance.mk").is_file()


@pytest.fixture(scope="module")
def repo_root() -> Path:
    """The repo root path."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    if not _make_available(root):
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"contain Make/maintenance.mk."
            )
        pytest.skip(f"Make/maintenance.mk not reachable from {root}")
    return root


_REJECTED_PAYLOADS: tuple[str, ...] = (
    "`touch ${CANARY}`",
    "1; touch ${CANARY}",
    "1|touch ${CANARY}",
    "1&touch ${CANARY}",
    "1>${CANARY}",
    "'x",
    '"x',
    "1\\${CANARY}",
    "1$X",
    "1(2",
    "1)2",
    "1<2",
)


@pytest.mark.parametrize("payload", _REJECTED_PAYLOADS)
def test_make_guard_rejects_shell_metachar_payloads_in_version(
    repo_root: Path,
    tmp_path: Path,
    payload: str,
) -> None:
    """Each payload contains a shell metacharacter the guard whitelist
    must reject. Run `make -n bump-nginx VERSION=<payload>` and assert:
        * exit code is non-zero,
        * the canary file is NOT created.

    `-n` (dry-run) is sufficient because the guard fires at Make-parse
    time before any recipe line runs, and the canary side-effect is
    what we are defending against (firing during parse evaluation).
    """
    canary = tmp_path / "PWNED"
    assert not canary.exists()
    rendered_payload = payload.replace("${CANARY}", str(canary))

    result = subprocess.run(
        ["make", "-n", "-C", str(repo_root), "bump-nginx", f"VERSION={rendered_payload}"],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    assert result.returncode != 0, (
        f"Make accepted hostile VERSION={rendered_payload!r}; "
        f"stdout={result.stdout!r}, stderr={result.stderr!r}"
    )
    assert not canary.exists(), (
        f"Canary file was created during Make parse despite guard; "
        f"payload={rendered_payload!r}, stderr={result.stderr!r}"
    )


@pytest.mark.parametrize("payload", _REJECTED_PAYLOADS)
def test_make_guard_rejects_shell_metachar_payloads_in_config_revision(
    repo_root: Path,
    tmp_path: Path,
    payload: str,
) -> None:
    """Symmetric coverage for the CONFIG_REVISION whitelist."""
    canary = tmp_path / "PWN_CR"
    assert not canary.exists()
    rendered_payload = payload.replace("${CANARY}", str(canary))

    result = subprocess.run(
        [
            "make",
            "-n",
            "-C",
            str(repo_root),
            "bump-nginx",
            "VERSION=1.31",
            f"CONFIG_REVISION={rendered_payload}",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    assert result.returncode != 0
    assert not canary.exists()


def test_make_guard_accepts_well_formed_version(repo_root: Path) -> None:
    """Sanity: the dry-run for a legitimate VERSION value succeeds."""
    result = subprocess.run(
        ["make", "-n", "-C", str(repo_root), "bump-nginx", "VERSION=1.31"],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    assert result.returncode == 0, (
        f"Make rejected legitimate VERSION=1.31; "
        f"stdout={result.stdout!r}, stderr={result.stderr!r}"
    )
    # Make's bump-nginx target must delegate to the script form.
    assert "./scripts/bump-nginx.sh" in result.stdout


def test_make_guard_accepts_well_formed_config_revision(repo_root: Path) -> None:
    """Sanity: a legitimate CONFIG_REVISION value combined with a
    well-formed VERSION lets the dry-run succeed. Pins the positive
    half of the contract so an over-zealous future guard that rejects
    all CONFIG_REVISION values is caught."""
    result = subprocess.run(
        [
            "make",
            "-n",
            "-C",
            str(repo_root),
            "bump-nginx",
            "VERSION=1.31",
            "CONFIG_REVISION=2",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    assert result.returncode == 0
    assert "--config-revision 2" in result.stdout


def test_make_guard_accepts_well_formed_mariadb_version(repo_root: Path) -> None:
    """Sanity: a legitimate VERSION lets the bump-mariadb dry-run
    succeed AND delegates to the script form. Symmetric with
    `test_make_guard_accepts_well_formed_version` so a future
    regression that re-introduces the inline docker invocation
    for bump-mariadb only is caught."""
    result = subprocess.run(
        ["make", "-n", "-C", str(repo_root), "bump-mariadb", "VERSION=11.9"],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    assert result.returncode == 0, (
        f"Make rejected legitimate VERSION=11.9; "
        f"stdout={result.stdout!r}, stderr={result.stderr!r}"
    )
    # Make's bump-mariadb target must delegate to the script form.
    assert "./scripts/bump-mariadb.sh" in result.stdout
