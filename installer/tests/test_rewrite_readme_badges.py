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
  * `main()` is a thin argv + file-IO shim — exercise it via
    `--versions` / `--readme` flag injection (in-process) so the exit
    codes / `::error::` annotation contract is pinned without depending
    on the host's cwd. One additional subprocess test runs the script
    with `cwd=tmp_path` and no flags to pin the workflow's default-path
    invocation contract.
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


def test_main_emits_error_annotation_and_exits_one_on_no_match(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """If the README badge URL shape changed (zero matches), exit 1 with
    a `::error::` annotation so the GitHub Actions run fails loud."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees":"2.2.6","php":"8.5"}]\n', encoding="utf-8"
    )
    readme = tmp_path / "README.md"
    readme.write_text("no badges here", encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        ["rewriter", "--versions", str(versions), "--readme", str(readme)],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::README badge rewrite no-op" in err
    assert readme.read_text(encoding="utf-8") == "no badges here"


def test_extract_unique_strips_whitespace(rewriter: ModuleType) -> None:
    """A hand-edited `"8.3 "` (trailing space) must NOT land in the
    badge URL as a literal space. The catalog filter strips on the
    way in so the canonical badge value is the trimmed form."""
    catalog: list[dict[str, object]] = [
        {"webtrees": "2.2.6 ", "php": "8.5"},
        {"webtrees": "2.2.6", "php": " 8.4"},
    ]
    wt = rewriter._extract_unique(catalog, "webtrees")
    php = rewriter._extract_unique(catalog, "php")
    assert wt == ["2.2.6"]
    assert php == ["8.4", "8.5"]


def test_extract_unique_skips_non_dict_rows(rewriter: ModuleType) -> None:
    """A catalog with stray non-dict rows (scalars, lists, None
    introduced by a botched JSON merge or hand-edit) must not crash
    the extractor with AttributeError — the filter is defensive at
    the row level too, not just the field level. Pins the
    `isinstance(row, dict)` guard so a regression that drops it would
    surface here rather than as a Python traceback on the workflow."""
    catalog: list[object] = [
        {"webtrees": "2.2.6", "php": "8.5"},
        "stray-scalar",
        42,
        None,
        ["array", "row"],
        {"webtrees": "2.1.27", "php": "8.4"},
    ]
    wt = rewriter._extract_unique(catalog, "webtrees")
    php = rewriter._extract_unique(catalog, "php")
    assert wt == ["2.1.27", "2.2.6"]
    assert php == ["8.4", "8.5"]


def test_extract_unique_skips_non_string_and_empty_rows(
    rewriter: ModuleType,
) -> None:
    """Catalog rows where the field is missing, None, a number, an
    array, or empty-after-strip are dropped silently. The filter is
    defensive: a hand-edit typo in versions.json must not crash the
    rewriter mid-run."""
    catalog: list[dict[str, object]] = [
        {"webtrees": "2.2.6", "php": "8.5"},
        {"webtrees": None, "php": "8.4"},
        {"webtrees": 42, "php": "8.3"},
        {"webtrees": "  ", "php": ""},
        {"webtrees": ["arr"], "php": "8.5"},
        {"php": "8.5"},
    ]
    wt = rewriter._extract_unique(catalog, "webtrees")
    php = rewriter._extract_unique(catalog, "php")
    assert wt == ["2.2.6"]
    assert php == ["8.3", "8.4", "8.5"]


def test_natural_sort_key_buckets_non_numeric_segments_at_zero(
    rewriter: ModuleType,
) -> None:
    """Pre-release segments like `0-beta` are non-numeric. The key
    function buckets them at 0 so `2.3.0-beta.1` keys to (2,3,0,1)
    and sorts after `2.3.0` → (2,3,0) (Python tuple comparison
    treats the longer-prefix-equal tuple as greater)."""
    assert rewriter._natural_sort_key("2.3.0") == (2, 3, 0)
    assert rewriter._natural_sort_key("2.3.0-beta.1") == (2, 3, 0, 1)
    assert rewriter._natural_sort_key("2.3.0-beta") == (2, 3, 0)
    # Stable-sort tie: `2.3.0` and `2.3.0-beta` key identically.
    items = ["2.3.0", "2.3.0-beta"]
    assert sorted(items, key=rewriter._natural_sort_key) == items


def test_resolve_from_catalog_fails_loud_on_empty_results(
    rewriter: ModuleType,
    tmp_path: Path,
) -> None:
    """A catalog whose rows ALL filter out (e.g. every .webtrees is
    null) must raise ValueError with an actionable message naming
    the empty field."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees": null, "php": "8.5"}]\n', encoding="utf-8"
    )
    with pytest.raises(ValueError, match="no non-empty .webtrees string values"):
        rewriter._resolve_from_catalog(versions)


def test_resolve_from_catalog_fails_loud_on_empty_php(
    rewriter: ModuleType,
    tmp_path: Path,
) -> None:
    """Symmetric to the webtrees-empty case: when `.webtrees` resolves
    but every `.php` row filters out, the php-specific error path must
    fire with its own actionable message. Pins the second branch in
    `_resolve_from_catalog` so a future refactor consolidating the two
    checks into a single message cannot regress the php-specific
    diagnostic string."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees":"2.2.6","php":null}]\n', encoding="utf-8"
    )
    with pytest.raises(ValueError, match="no non-empty .php string values"):
        rewriter._resolve_from_catalog(versions)


def test_main_natural_sort_handles_pre_release_in_catalog(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """End-to-end: a catalog mixing `2.3.0` + `2.3.0-beta.1` produces
    badge values in stable-adjacent order (release first by tuple
    comparison, pre-release after). Pins the natural-sort contract
    for the non-numeric-segment branch."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '['
        '{"webtrees":"2.3.0","php":"8.5","tags":["latest"]},'
        '{"webtrees":"2.3.0-beta.1","php":"8.5"}'
        ']\n',
        encoding="utf-8",
    )
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-old-787CB5)]\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(
        sys,
        "argv",
        ["rewriter", "--versions", str(versions), "--readme", str(readme)],
    )
    rc = rewriter.main()
    assert rc == 0
    body = readme.read_text(encoding="utf-8")
    # 2.3.0 keys to (2,3,0); 2.3.0-beta.1 keys to (2,3,0,1) — the
    # longer-prefix-equal tuple sorts AFTER, so release before
    # pre-release in the badge URL.
    assert "webtrees-2.3.0%7C2.3.0-beta.1-blue" in body


def test_script_is_executable_under_python3(tmp_path: Path) -> None:
    """Smoke-execute the script as a subprocess so any syntax-level
    breakage (indentation, shebang, top-level import error) surfaces
    at PR time. Invokes the script with explicit `--versions` /
    `--readme` paths so the test never depends on cwd or on any real
    dev/versions.json file in the host's working directory."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "rewrite-readme-badges.py"
    if not script.is_file():
        pytest.skip(f"rewriter script missing: {script}")

    # Minimal valid fixtures so the catalog-driven path runs end-to-end.
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees":"2.2.6","php":"8.5","tags":["latest"]}]\n',
        encoding="utf-8",
    )
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-old-787CB5)]\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "--versions",
            str(versions),
            "--readme",
            str(readme),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, (
        f"rewriter script failed to parse / run: rc={result.returncode}, "
        f"stderr={result.stderr!r}"
    )
    body = readme.read_text(encoding="utf-8")
    assert "webtrees-2.2.6-blue" in body
    assert "PHP-8.5-787CB5" in body


def test_main_reads_catalog_and_sorts_naturally(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Default invocation (no positional args) reads the catalog at
    --versions, extracts unique values, sorts naturally, and rewrites
    the README. Pins the natural-sort contract: `8.10` lands after
    `8.5`, `2.1.27` lands before `2.2.6`."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '['
        '{"webtrees":"2.2.6","php":"8.10","tags":["latest"]},'
        '{"webtrees":"2.2.6","php":"8.5"},'
        '{"webtrees":"2.2.6","php":"8.3"},'
        '{"webtrees":"2.1.27","php":"8.5"}'
        ']\n',
        encoding="utf-8",
    )
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-old-787CB5)]\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "rewriter",
            "--versions",
            str(versions),
            "--readme",
            str(readme),
        ],
    )
    rc = rewriter.main()
    assert rc == 0
    body = readme.read_text(encoding="utf-8")
    # Natural sort: 2.1.27 BEFORE 2.2.6; 8.3 BEFORE 8.5 BEFORE 8.10.
    assert "webtrees-2.1.27%7C2.2.6-blue" in body
    assert "PHP-8.3%7C8.5%7C8.10-787CB5" in body


def test_main_fails_loud_on_malformed_catalog(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A catalog that is not a JSON array (e.g. an object, scalar, or
    parse error) surfaces an actionable `::error::cannot extract
    badge values` line, not a Python traceback."""
    versions = tmp_path / "versions.json"
    versions.write_text('{"not": "an array"}', encoding="utf-8")
    readme = tmp_path / "README.md"
    readme.write_text("placeholder", encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        ["rewriter", "--versions", str(versions), "--readme", str(readme)],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::cannot extract badge values" in err
    assert "ValueError" in err


def test_main_exits_one_when_only_php_badge_is_missing(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Pins the asymmetric `if n_wt == 0 or n_php == 0:` predicate. A
    README that carries the webtrees badge but is missing the PHP one
    must still exit 1 with `webtrees=1 php=0` in the annotation so a
    future refactor flipping `or` to `and` cannot regress detection of
    a partial-match shape change."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees":"2.2.6","php":"8.5"}]\n', encoding="utf-8"
    )
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "(no PHP badge here)\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(
        sys,
        "argv",
        ["rewriter", "--versions", str(versions), "--readme", str(readme)],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::README badge rewrite no-op" in err
    assert "webtrees=1" in err
    assert "php=0" in err


def test_main_default_paths_resolve_relative_to_cwd(
    tmp_path: Path,
) -> None:
    """Pins the workflow's no-arg invocation contract: check-versions.yml
    runs `python3 scripts/rewrite-readme-badges.py` with no flags and
    relies on `dev/versions.json` + `README.md` resolving against the
    workflow's cwd. A future refactor that changed the argparse default
    literals would break the workflow but pass every other test, so
    this is the only place pinning the default-path semantics."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "rewrite-readme-badges.py"
    if not script.is_file():
        pytest.skip(f"rewriter script missing: {script}")

    (tmp_path / "dev").mkdir()
    (tmp_path / "dev" / "versions.json").write_text(
        '[{"webtrees":"2.2.6","php":"8.5","tags":["latest"]}]\n',
        encoding="utf-8",
    )
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-old-787CB5)]\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, str(script)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, (
        f"rewriter default-path invocation failed: rc={result.returncode}, "
        f"stderr={result.stderr!r}"
    )
    body = readme.read_text(encoding="utf-8")
    assert "webtrees-2.2.6-blue" in body
    assert "PHP-8.5-787CB5" in body


def test_main_fails_loud_on_unparseable_json(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A catalog whose bytes are not valid JSON (truncated, trailing
    comma, raw garbage) surfaces an actionable
    `::error::cannot extract badge values` line via the
    `json.JSONDecodeError` arm of main()'s except tuple, not an
    uncaught traceback. Pins the JSONDecodeError branch separately
    from the ValueError + FileNotFoundError ones so a future refactor
    cannot quietly narrow the except tuple."""
    versions = tmp_path / "versions.json"
    versions.write_text("not-json-at-all", encoding="utf-8")
    readme = tmp_path / "README.md"
    readme.write_text("placeholder", encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        ["rewriter", "--versions", str(versions), "--readme", str(readme)],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::cannot extract badge values" in err
    assert "JSONDecodeError" in err


def test_main_fails_loud_when_readme_is_missing(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing or unreadable README surfaces via a dedicated
    `::error::cannot read README at ...` annotation rather than an
    uncaught Python traceback. Pins the symmetric try/except added
    around `args.readme.read_text()` so the rewriter fails with the
    same diagnostic shape as the companion shell script
    check-readme-badges.sh's `[ -f README.md ]` guard."""
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees":"2.2.6","php":"8.5","tags":["latest"]}]\n',
        encoding="utf-8",
    )
    missing_readme = tmp_path / "MISSING_README.md"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "rewriter",
            "--versions",
            str(versions),
            "--readme",
            str(missing_readme),
        ],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::cannot read README at" in err
    assert "FileNotFoundError" in err


def test_main_fails_loud_when_readme_is_not_writable(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A non-writable README path surfaces via a dedicated
    `::error::cannot write README at ...` annotation. Pins the
    second try/except guarding `args.readme.write_text()`.

    Uses chmod to drop write permission on a fixture file after the
    read succeeds. CI runs as a non-root user so the chmod 0444 is
    effective; skipped on platforms where chmod is a no-op (Windows
    NTFS without ACLs)."""
    if sys.platform == "win32":
        pytest.skip("chmod write-permission semantics unreliable on Windows")
    versions = tmp_path / "versions.json"
    versions.write_text(
        '[{"webtrees":"2.2.6","php":"8.5","tags":["latest"]}]\n',
        encoding="utf-8",
    )
    readme = tmp_path / "README.md"
    readme.write_text(
        "[![webtrees](https://img.shields.io/badge/webtrees-old-blue)]\n"
        "[![PHP](https://img.shields.io/badge/PHP-old-787CB5)]\n",
        encoding="utf-8",
    )
    # Make the file read-only (0444) AND the parent directory non-writable
    # (0555). Either alone is insufficient on POSIX because `write_text`
    # may unlink + recreate; both together ensure the write fails.
    readme.chmod(0o444)
    tmp_path.chmod(0o555)
    try:
        monkeypatch.setattr(
            sys,
            "argv",
            ["rewriter", "--versions", str(versions), "--readme", str(readme)],
        )
        rc = rewriter.main()
    finally:
        # Restore so pytest's tmp_path cleanup can succeed.
        tmp_path.chmod(0o755)
        readme.chmod(0o644)
    if rc == 0:
        pytest.skip(
            "running as root or filesystem ignores chmod; cannot exercise "
            "write-failure path in this environment"
        )
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::cannot write README at" in err
    assert "PermissionError" in err or "OSError" in err


def test_main_encodes_exception_newlines_as_percent_0a(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A `::error::` annotation in GitHub Actions is line-based; an
    embedded `\\n` in the exception message terminates the
    annotation, dropping the rest of the detail. The rewriter
    replaces literal newlines with `%0A` so multi-line exception
    text renders correctly. Pins the `.replace('\\n', '%0A')`
    branch so a future refactor that drops it cannot silently
    truncate the annotation.

    Monkeypatches `_resolve_from_catalog` to raise a ValueError
    with embedded newlines — the natural `FileNotFoundError` /
    `JSONDecodeError` / `ValueError(no .webtrees values)` cases
    all produce single-line str() output, so a contrived
    multi-line exception is the only way to exercise the
    transformation directly."""
    versions = tmp_path / "versions.json"
    versions.write_text("[]", encoding="utf-8")
    readme = tmp_path / "README.md"
    readme.write_text("placeholder", encoding="utf-8")

    def raise_multiline(_path: object) -> tuple[str, str]:
        raise ValueError("first line\nsecond line\nthird line")

    monkeypatch.setattr(rewriter, "_resolve_from_catalog", raise_multiline)
    monkeypatch.setattr(
        sys,
        "argv",
        ["rewriter", "--versions", str(versions), "--readme", str(readme)],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::cannot extract badge values" in err
    # Every embedded newline must be encoded as `%0A` so the entire
    # annotation lands on a single line in the GitHub Actions UI.
    assert "first line%0Asecond line%0Athird line" in err
    # Conversely, no literal newline may appear inside the annotation
    # detail (the trailing `\n` from `print()` is allowed).
    first_line = err.rstrip("\n")
    assert "\n" not in first_line, (
        f"annotation must be a single line, got: {first_line!r}"
    )


def test_main_fails_loud_on_missing_catalog(
    rewriter: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing catalog file surfaces an actionable FileNotFoundError
    annotation, not a bare traceback."""
    readme = tmp_path / "README.md"
    readme.write_text("placeholder", encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "rewriter",
            "--versions",
            str(tmp_path / "missing.json"),
            "--readme",
            str(readme),
        ],
    )
    rc = rewriter.main()
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::cannot extract badge values" in err
    assert "FileNotFoundError" in err
