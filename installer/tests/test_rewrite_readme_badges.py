"""Tests for `scripts/rewrite-readme-badges.py`.

The renderer is called by `check-versions.yml` after each upstream-release
auto-bump and must keep the static webtrees / PHP badge URLs in README.md
in lockstep with the unique values across `dev/versions.json`. The
renderer lives in its own file so the Python body cannot inherit YAML
indentation from the workflow scalar and is exercised here in isolation.

Coverage rationale:
  * `rewrite()` is the only pure function — exercise the substitution
    semantics directly (happy path, hyphen-bearing message field, missing
    badge, idempotency, regex-metachar argv).
  * `main()` is a thin argv + file-IO shim — exercise it via a tmp_path
    chdir so the exit codes / `::error::` annotation contract is pinned.
  * A subprocess smoke test runs the script as the workflow does, so any
    syntax-level regression (the heredoc-indent class of failure) surfaces
    at PR time instead of at cron time.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest


def _resolve_repo_root() -> Path | None:
    """Resolve the repo root using the WT_REPO_ROOT precedence pattern.

    Mirrors `test_mariadb_pin_lockstep._resolve_repo_root`. See that
    file for the rationale.
    """
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


def _load_rewriter() -> ModuleType:
    """Load the rewriter script by file path.

    The script has a hyphen in its name and lives outside any package,
    so the standard `import` machinery cannot reach it; `importlib.util`
    is the canonical workaround.

    Fail-loud-in-CI discipline mirrors the lockstep tests: a bogus
    `WT_REPO_ROOT` (wrong bind-mount in Make/ci.mk's ci-pytest)
    `pytest.fail`s instead of silently skipping so a misconfigured CI
    cannot lose rewriter coverage. Only a host-shell run without
    `WT_REPO_ROOT` falls through to the skip path.
    """
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "rewrite-readme-badges.py"
    if not script.is_file():
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"contain scripts/rewrite-readme-badges.py. Fix the "
                f"bind-mount in Make/ci.mk's ci-pytest target."
            )
        pytest.skip(f"rewriter script missing: {script}")
    spec = importlib.util.spec_from_file_location(
        "rewrite_readme_badges", script
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def rewriter() -> ModuleType:
    """The rewriter module, loaded once per test module."""
    return _load_rewriter()


def test_rewrite_substitutes_both_badges(rewriter: ModuleType) -> None:
    """Happy path: both badges get the new values; both regexes match
    exactly once."""
    text = (
        "[![webtrees](https://img.shields.io/badge/webtrees-2.1.27-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-8.3-787CB5)]\n"
    )
    new, n_wt, n_php = rewriter.rewrite(text, "2.1.27%7C2.2.6", "8.3%7C8.4%7C8.5")
    assert n_wt == 1
    assert n_php == 1
    assert "webtrees-2.1.27%7C2.2.6-blue" in new
    assert "PHP-8.3%7C8.4%7C8.5-787CB5" in new


def test_rewrite_handles_hyphenated_existing_value(rewriter: ModuleType) -> None:
    """The non-greedy `.+?` must consume hyphens inside the old badge
    value (a pre-release tag like `2.3.0-beta.1` becomes part of the
    URL message field on the next bump)."""
    text = "img.shields.io/badge/webtrees-2.3.0-beta.1-blue"
    new, n_wt, _ = rewriter.rewrite(text, "2.4.0", "8.5")
    assert n_wt == 1
    assert new == "img.shields.io/badge/webtrees-2.4.0-blue"


def test_rewrite_reports_zero_match_for_missing_badge(rewriter: ModuleType) -> None:
    """Caller relies on `n_wt == 0` / `n_php == 0` to fail the workflow
    loud. The function must not raise — just report the count."""
    text = "no badges here at all"
    _, n_wt, n_php = rewriter.rewrite(text, "x", "y")
    assert n_wt == 0
    assert n_php == 0


def test_rewrite_is_idempotent_on_already_current_text(rewriter: ModuleType) -> None:
    """Running the rewriter twice with the same inputs is a no-op on
    pass two — important for the workflow's `git diff --quiet` follow-up
    that decides whether to commit."""
    text = (
        "img.shields.io/badge/webtrees-2.1.27%7C2.2.6-blue "
        "img.shields.io/badge/PHP-8.3%7C8.4%7C8.5-787CB5"
    )
    once, *_ = rewriter.rewrite(text, "2.1.27%7C2.2.6", "8.3%7C8.4%7C8.5")
    twice, *_ = rewriter.rewrite(once, "2.1.27%7C2.2.6", "8.3%7C8.4%7C8.5")
    assert once == twice == text


def test_rewrite_accepts_backslash_metachar_argv(rewriter: ModuleType) -> None:
    """Replacement values containing regex backreference metacharacters
    must produce literal output. The callable-replacement form makes
    this a safe identity substitution. The f-string-replacement form
    fails differently per metachar: `\\1` raises
    `re.error: invalid group reference`, `\\g<0>` silently substitutes
    the whole match into the message field producing a corrupt URL.
    Either failure mode would fail the substring assertions below."""
    text = (
        "img.shields.io/badge/webtrees-old-blue "
        "img.shields.io/badge/PHP-old-787CB5"
    )
    new, n_wt, n_php = rewriter.rewrite(text, r"\1", r"\g<0>")
    assert n_wt == 1
    assert n_php == 1
    assert r"webtrees-\1-blue" in new
    assert r"PHP-\g<0>-787CB5" in new


def test_main_writes_file_and_exits_zero(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """End-to-end: argv parsing + file read + write + exit 0."""
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-old-787CB5)]\n",
        encoding="utf-8",
    )
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["rewriter", "2.2.6", "8.5"])
    rc = rewriter.main()
    assert rc == 0
    body = readme.read_text(encoding="utf-8")
    assert "webtrees-2.2.6-blue" in body
    assert "PHP-8.5-787CB5" in body


def test_main_emits_error_annotation_and_exits_one_on_no_match(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """If the README badge URL shape changed (zero matches), exit 1 with
    a `::error::` annotation so the GitHub Actions run fails loud."""
    readme = tmp_path / "README.md"
    readme.write_text("no badges here", encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["rewriter", "2.2.6", "8.5"])
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::README badge rewrite no-op" in err
    assert readme.read_text(encoding="utf-8") == "no badges here"


def test_main_exits_one_when_only_php_badge_missing(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Asymmetric: webtrees badge present, PHP badge absent. The `or`
    in `n_wt == 0 or n_php == 0` must still trip; the annotation must
    name both counts so an operator can localise the missing badge."""
    readme = tmp_path / "README.md"
    readme.write_text(
        "img.shields.io/badge/webtrees-old-blue", encoding="utf-8"
    )
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["rewriter", "2.2.6", "8.5"])
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "webtrees=1 php=0" in err
    assert readme.read_text(encoding="utf-8") == "img.shields.io/badge/webtrees-old-blue"


def test_main_rejects_wrong_argv_count(
    rewriter: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Defensive: a wrong invocation from the workflow (e.g. one missing
    value) must fail with exit 2 rather than silently treating the
    missing arg as an empty string."""
    monkeypatch.setattr(sys, "argv", ["rewriter", "only-one"])
    rc = rewriter.main()
    assert rc == 2
    assert "usage:" in capsys.readouterr().err


def test_script_is_executable_under_python3() -> None:
    """Smoke-execute the script as a subprocess so any syntax-level
    breakage (indentation, shebang, top-level import error) surfaces
    at PR time. Without this, a future inline-vs-extracted regression
    could pass `pytest` while crashing under the workflow's
    `python3 scripts/rewrite-readme-badges.py …` invocation."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "rewrite-readme-badges.py"
    if not script.is_file():
        pytest.skip(f"rewriter script missing: {script}")
    result = subprocess.run(
        [sys.executable, str(script)],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 2, (
        f"rewriter script failed to parse / run: rc={result.returncode}, "
        f"stderr={result.stderr!r}"
    )
    assert "usage:" in result.stderr
