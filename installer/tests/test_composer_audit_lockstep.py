"""Lockstep guard for the Composer audit of the setup manifests.

The image build selects one of the `setup/composer-*.json` manifests by the
webtrees version, so the repository root has no `composer.json` for the shared
Composer audit to read. The security workflow therefore calls the shared audit
once per manifest file of `setup/` through a matrix. A manifest that is added
to `setup/` without a matrix entry is never audited, and an entry for a file
that no longer exists fails the job, so this test keeps both sides equal.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest
import yaml


_SHARED_WORKFLOW = "magicsunday/.github/.github/workflows/composer-audit.yml@"


def _looks_like_repo_root(root: Path) -> bool:
    """Anchor-file check: a candidate path is a real repo root iff both
    `dev/versions.json` and `installer/pyproject.toml` exist underneath it."""
    return (root / "dev" / "versions.json").is_file() and (
        root / "installer" / "pyproject.toml"
    ).is_file()


def _audit_job(root: Path) -> dict[str, Any]:
    """Return the `composer-audit` job of the security workflow."""
    document = yaml.safe_load(
        (root / ".github" / "workflows" / "security.yml").read_text(encoding="utf-8")
    )
    job: dict[str, Any] = document["jobs"]["composer-audit"]
    return job


@pytest.fixture
def repo_root(resolved_repo_root: Path | None) -> Path:
    """The repo root, or a skip for a partial checkout."""
    if resolved_repo_root is None or not _looks_like_repo_root(resolved_repo_root):
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"resolve to a real repo root. Fix the bind-mount in "
                f"Make/ci.mk's ci-pytest target."
            )
        pytest.skip("repo root not reachable from an installed wheel or partial checkout.")
    return resolved_repo_root


def test_matrix_names_every_manifest_of_the_setup_directory(repo_root: Path) -> None:
    """Every `setup/composer-*.json` file is audited and nothing else is."""
    job = _audit_job(repo_root)
    matrix = job["strategy"]["matrix"]["file"]
    manifests = sorted(path.name for path in (repo_root / "setup").glob("composer-*.json"))

    assert manifests, "setup/ holds no composer-*.json manifest"
    assert sorted(matrix) == manifests, (
        "the matrix of the composer-audit job must name exactly the manifests of setup/"
    )


def test_job_hands_the_matrix_file_to_the_shared_audit(repo_root: Path) -> None:
    """The job audits the setup directory and reads the file of its matrix entry."""
    job = _audit_job(repo_root)

    assert str(job["uses"]).startswith(_SHARED_WORKFLOW)
    assert job["with"] == {
        "working-directory": "setup",
        "composer-file": "${{ matrix.file }}",
    }


def test_matrix_runs_every_manifest_even_after_a_failure(repo_root: Path) -> None:
    """One vulnerable manifest must not hide the result of the other manifests."""
    job = _audit_job(repo_root)

    assert job["strategy"]["fail-fast"] is False
