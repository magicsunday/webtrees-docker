"""Lockstep guard for the Composer audit of the setup manifests.

The image build selects one of the `setup/composer-*.json` manifests by the
webtrees version, so the repository root has no `composer.json` for the shared
Composer audit to read. The security workflow therefore calls the shared audit
once per manifest file of `setup/` through a matrix. A manifest that is added
to `setup/` without a matrix entry is never audited, and an entry for a file
that no longer exists fails the job, so this test keeps both sides equal.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


_SHARED_WORKFLOW = "magicsunday/.github/.github/workflows/composer-audit.yml@"


def _audit_job(root: Path) -> dict[str, Any]:
    """Return the `composer-audit` job of the security workflow."""
    document = yaml.safe_load(
        (root / ".github" / "workflows" / "security.yml").read_text(encoding="utf-8")
    )
    job: dict[str, Any] = document["jobs"]["composer-audit"]
    return job


def test_matrix_names_every_manifest_of_the_setup_directory(validated_repo_root: Path) -> None:
    """Every `setup/composer-*.json` file is audited and nothing else is."""
    job = _audit_job(validated_repo_root)
    matrix = job["strategy"]["matrix"]["file"]
    manifests = sorted(path.name for path in (validated_repo_root / "setup").glob("composer-*.json"))

    assert manifests, "setup/ holds no composer-*.json manifest"
    assert sorted(matrix) == manifests, (
        "the matrix of the composer-audit job must name exactly the manifests of setup/"
    )


def test_job_hands_the_matrix_file_to_the_shared_audit(validated_repo_root: Path) -> None:
    """The job audits the setup directory and reads the file of its matrix entry."""
    job = _audit_job(validated_repo_root)

    assert str(job["uses"]).startswith(_SHARED_WORKFLOW)
    assert job["with"] == {
        "working-directory": "setup",
        "composer-file": "${{ matrix.file }}",
    }


def test_matrix_runs_every_manifest_even_after_a_failure(validated_repo_root: Path) -> None:
    """One vulnerable manifest must not hide the result of the other manifests."""
    job = _audit_job(validated_repo_root)

    assert job["strategy"]["fail-fast"] is False
