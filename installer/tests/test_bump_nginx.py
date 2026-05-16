"""Tests for `scripts/bump-nginx.py`.

The bump tool is one-shot maintenance tooling invoked by an operator
to action a `check-nginx.yml` tracking issue. The lockstep test
`test_nginx_tag_lockstep` is the safety net, but a broken bump tool
would leave the working tree in a half-mutated state that the
operator has to revert by hand — these tests pin the contract so
that does not happen silently.

Coverage rationale:
  * `bump()` is the pure entry point — exercise each branch
    (idempotency reject, malformed minor reject, missing canonical,
    happy path, mirror miss).
  * `main()` is a thin argv shim — exercise it once via subprocess
    so any syntax-level breakage surfaces at PR time.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest


def _resolve_repo_root() -> Path | None:
    """Resolve the repo root using the WT_REPO_ROOT precedence pattern.

    Mirrors `test_mariadb_pin_lockstep._resolve_repo_root` — see that
    file for the rationale.
    """
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


def _load_bumper() -> ModuleType:
    """Load `scripts/bump-nginx.py` by file path.

    Hyphen-in-name forces `importlib.util` over the standard import
    machinery. Fail-loud-in-CI discipline matches the rewriter test:
    bogus WT_REPO_ROOT inside CI must not silently skip coverage.
    """
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "bump-nginx.py"
    if not script.is_file():
        if os.environ.get("WT_REPO_ROOT"):
            pytest.fail(
                f"WT_REPO_ROOT={os.environ['WT_REPO_ROOT']!r} does not "
                f"contain scripts/bump-nginx.py. Fix the bind-mount in "
                f"Make/ci.mk's ci-pytest target."
            )
        pytest.skip(f"bumper script missing: {script}")
    spec = importlib.util.spec_from_file_location("bump_nginx", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def bumper() -> ModuleType:
    """The bumper module, loaded once per test module."""
    return _load_bumper()


def _seed_repo(root: Path, tag: str = "1.30-r1") -> None:
    """Write a minimal canonical + the five mirror sites under `root`.

    Each mirror gets the literal `webtrees-nginx:<tag>` so the bumper
    finds at least one substitution per site. Real repo content is
    irrelevant to the bumper's contract — only the tag literal matters.
    """
    base, _, rev_suffix = tag.partition("-")
    # `1.30-r3` → revision 3. Match the canonical's own format so a
    # test seeding `tag="1.30-r3"` lands with `config_revision: 3`,
    # not a hardcoded 1.
    revision = int(rev_suffix.lstrip("r")) if rev_suffix else 1
    (root / "dev").mkdir(parents=True, exist_ok=True)
    (root / "dev" / "nginx-version.json").write_text(
        json.dumps(
            {"nginx_base": base, "config_revision": revision, "tag": tag},
            indent=4,
        )
        + "\n",
        encoding="utf-8",
    )
    (root / "Make").mkdir(parents=True, exist_ok=True)
    (root / "Make" / "ci.mk").write_text(
        f'NGINX_IMAGE="ghcr.io/magicsunday/webtrees-nginx:{tag}"\n',
        encoding="utf-8",
    )
    (root / "tests").mkdir(parents=True, exist_ok=True)
    (root / "tests" / "test-nginx-config.sh").write_text(
        f'NGINX_IMAGE="${{TEST_NGINX_IMAGE:-ghcr.io/magicsunday/webtrees-nginx:{tag}}}"\n',
        encoding="utf-8",
    )
    (root / "tests" / "test-trust-proxy-extra.sh").write_text(
        f'NGINX_IMAGE="${{TEST_NGINX_IMAGE:-ghcr.io/magicsunday/webtrees-nginx:{tag}}}"\n',
        encoding="utf-8",
    )
    (root / "templates" / "portainer").mkdir(parents=True, exist_ok=True)
    (root / "templates" / "portainer" / "compose.yaml").write_text(
        f"image: ghcr.io/magicsunday/webtrees-nginx:{tag}\n",
        encoding="utf-8",
    )
    (root / "README.md").write_text(
        f"docker pull ghcr.io/magicsunday/webtrees-nginx:{tag}\n",
        encoding="utf-8",
    )


def test_bump_writes_canonical_and_syncs_all_mirrors(
    bumper: ModuleType, tmp_path: Path
) -> None:
    """Happy path: nginx 1.30-r1 -> 1.32-r1 (next stable minor).
    Canonical JSON is rewritten and every mirror site picks up the
    new tag."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 0
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical == {"nginx_base": "1.32", "config_revision": 1, "tag": "1.32-r1"}
    for relative in (
        "Make/ci.mk",
        "tests/test-nginx-config.sh",
        "tests/test-trust-proxy-extra.sh",
        "templates/portainer/compose.yaml",
        "README.md",
    ):
        body = (tmp_path / relative).read_text(encoding="utf-8")
        assert "webtrees-nginx:1.32-r1" in body
        assert "webtrees-nginx:1.30-r1" not in body


def test_bump_rejects_same_minor_with_same_revision(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Idempotency: re-bumping the already-pinned minor + revision is
    a no-op the operator must explicitly intend (via --config-revision)."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.30", config_revision=1)
    assert rc == 1
    err = capsys.readouterr().err
    assert "already at 1.30-r1" in err
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical["tag"] == "1.30-r1"


def test_bump_allows_revision_only_increment(
    bumper: ModuleType, tmp_path: Path
) -> None:
    """nginx.conf change without a minor bump: same `nginx_base`, but
    `config_revision` increments. Tag becomes `X.Y-r(N+1)`."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.30", config_revision=2)
    assert rc == 0
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical == {"nginx_base": "1.30", "config_revision": 2, "tag": "1.30-r2"}
    assert "webtrees-nginx:1.30-r2" in (
        tmp_path / "Make" / "ci.mk"
    ).read_text(encoding="utf-8")


def test_bump_rejects_patch_pinned_minor(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Pin policy: X.Y only. A `1.30.1` argv must fail with an
    actionable error rather than silently producing `1.30.1-r1`."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.30.1")
    assert rc == 1
    err = capsys.readouterr().err
    assert "must match X.Y" in err


def test_bump_rejects_odd_mainline_minor(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Stable-only policy: nginx publishes even-numbered minors on the
    stable line (1.26, 1.28, 1.30, …) and odd minors on mainline. An
    odd-minor bump must fail loud before mutating the canonical or
    any mirror site — this prevents the cascade where the bump lands,
    the lockstep tests pass (they only verify mirror agreement, not
    the minor's parity), the PR merges, and only the daily
    check-nginx.yml self-test catches the policy violation 24h later."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.31")
    assert rc == 1
    err = capsys.readouterr().err
    assert "mainline" in err
    assert "stable" in err
    # Canonical must remain unchanged on policy-violation reject.
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical["nginx_base"] == "1.30"


def test_bump_rejects_leading_zero_minor(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Pin policy: canonical form is `X.Y` without leading zeros.
    `1.030` would parse as int 30 (even, parity-clean) and silently
    pin a `webtrees-nginx:1.030-r1` tag that no Docker Hub variant
    publishes. The tightened regex must reject leading-zero shapes
    before mutating any file."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.030")
    assert rc == 1
    err = capsys.readouterr().err
    assert "must match X.Y" in err
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical["nginx_base"] == "1.30"


def test_bump_fails_loud_on_odd_current_base_seed(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A poisoned canonical (`current_base` on an odd-minor mainline
    minor) misdirects the operator if the bumper proceeds — the mirror
    sed would diagnose 'missing literal' and the message would point
    at the mirrors, not the actual root cause. The current-pin parity
    self-check must catch the policy violation upfront."""
    _seed_repo(tmp_path, tag="1.31-r1")
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "mainline" in err
    assert "policy-violating state" in err
    # The canonical is left untouched so the operator can restore by
    # hand without first reverting an in-flight write.
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical["nginx_base"] == "1.31"


def test_bump_rejects_non_monotonic_downgrade(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Monotonic-bump guard: a downgrade (1.30 → 1.28) goes through
    the regex + parity + canonical checks cleanly, but must be
    rejected as a downgrade. Genuine rollbacks need an explicit
    manual JSON edit so they land in commit history with intent."""
    _seed_repo(tmp_path)
    rc = bumper.bump(tmp_path, "1.28")
    assert rc == 1
    err = capsys.readouterr().err
    assert "older than the current pin" in err
    assert "refuses to downgrade" in err
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical["nginx_base"] == "1.30"


def test_bump_rejects_revision_only_downgrade(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Same-minor revision downgrade (1.30-r3 → 1.30-r1) goes through
    the regex / parity / canonical / idempotency checks (1 != 3, so
    not idempotent) and the minor-tuple comparison is equal, so a
    naive minor-only monotonic guard would let it through. The
    extended guard compares (parts, config_revision) so the rollback
    is caught here."""
    _seed_repo(tmp_path, tag="1.30-r3")
    rc = bumper.bump(tmp_path, "1.30", config_revision=1)
    assert rc == 1
    err = capsys.readouterr().err
    assert "older than the current pin" in err
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical["tag"] == "1.30-r3"


def test_bump_fails_loud_when_canonical_json_is_invalid(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A canonical file that parses cleanly as a path but not as JSON
    must surface an actionable `::error::canonical malformed` line,
    not a Python traceback. Downstream consumers (CI annotations,
    operator log grep) rely on the `::error::` prefix for failure
    detection."""
    _seed_repo(tmp_path)
    (tmp_path / "dev" / "nginx-version.json").write_text(
        "not json {{{", encoding="utf-8"
    )
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::canonical malformed" in err
    assert "JSONDecodeError" in err


def test_bump_fails_loud_when_canonical_json_is_missing_key(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A canonical JSON with the wrong shape (missing `nginx_base`)
    must surface a `::error::canonical malformed` line naming the
    error type, not a bare KeyError traceback."""
    _seed_repo(tmp_path)
    (tmp_path / "dev" / "nginx-version.json").write_text(
        '{"config_revision": 1, "tag": "1.30-r1"}\n', encoding="utf-8"
    )
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::canonical malformed" in err
    assert "KeyError" in err


def test_bump_fails_loud_when_canonical_config_revision_is_non_integer(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The except clause covers ValueError too: a canonical with a
    non-integer `config_revision` (e.g. an accidentally-quoted value)
    must surface the malformed-canonical error, not a ValueError
    traceback from `int()`."""
    _seed_repo(tmp_path)
    (tmp_path / "dev" / "nginx-version.json").write_text(
        '{"nginx_base":"1.30","config_revision":"not-a-number","tag":"1.30-r1"}\n',
        encoding="utf-8",
    )
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "::error::canonical malformed" in err
    assert "ValueError" in err


def test_bump_fails_loud_when_current_base_is_malformed_x_y(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A canonical with an nginx_base value that parses cleanly as
    JSON string but does not match X.Y (e.g. patch-pinned `1.30.5`,
    leading-zero `01.30`, or garbage `abc`) must surface the
    `is malformed` error before the parity check or any mutation."""
    _seed_repo(tmp_path)
    (tmp_path / "dev" / "nginx-version.json").write_text(
        '{"nginx_base":"1.30.5","config_revision":1,"tag":"1.30.5-r1"}\n',
        encoding="utf-8",
    )
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "is malformed" in err
    assert "restore a clean X.Y stable pin" in err


def test_main_rejects_non_positive_config_revision(
    bumper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """`--config-revision 0` and negative values must be rejected at
    argv parse time. A cross-minor bump with a negative revision
    (e.g. `--config-revision -5 1.32` against canonical 1.28) would
    otherwise slip past the monotonic guard (minor dominates the
    tuple compare) and produce a malformed tag like `1.32-r-5` that
    the lockstep regex `r[0-9]+` can't match — misdirecting the
    operator toward a mirror-drift diagnosis."""
    monkeypatch.setattr(
        sys, "argv", ["bump-nginx", "--config-revision", "-5", "1.32"]
    )
    rc = bumper.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "must be a positive integer" in err

    monkeypatch.setattr(
        sys, "argv", ["bump-nginx", "--config-revision", "0", "1.32"]
    )
    rc = bumper.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "must be a positive integer" in err


def test_bump_fails_loud_when_canonical_missing(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """No canonical JSON under the working directory: refuse rather
    than fabricating one."""
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "canonical file missing" in err


def test_bump_fails_loud_when_mirror_lacks_pin_literal(
    bumper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A mirror site that no longer carries the expected
    `webtrees-nginx:X.Y-rN` literal is a structural-drift indicator.
    The bumper must surface it; canonical is still written so the
    operator can choose to revert or restructure."""
    _seed_repo(tmp_path)
    (tmp_path / "Make" / "ci.mk").write_text("NGINX_IMAGE=\"some-other-form\"\n", encoding="utf-8")
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 1
    err = capsys.readouterr().err
    assert "mirror sync failed" in err
    assert "Make/ci.mk" in err


def test_main_rejects_wrong_argv_count(
    bumper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Defensive: a wrong invocation (zero or multiple positional args)
    must fail with exit 2 and a usage hint."""
    monkeypatch.setattr(sys, "argv", ["bump-nginx"])
    rc = bumper.main()
    assert rc == 2
    assert "usage:" in capsys.readouterr().err


def test_main_rejects_unknown_flag(
    bumper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Defensive: unknown flags (typo, future flag) must fail rather
    than silently being interpreted as a positional minor."""
    monkeypatch.setattr(sys, "argv", ["bump-nginx", "--foo", "1.31"])
    rc = bumper.main()
    assert rc == 2
    assert "unknown flag" in capsys.readouterr().err


def test_bump_does_not_corrupt_suffixed_tag_lookalike(
    bumper: ModuleType, tmp_path: Path
) -> None:
    """A mirror line carrying a future-shape `1.30-r1-debug` tag must
    NOT be rewritten to `1.31-r1-debug`. No mirror site uses a
    suffixed tag form; the negative-lookahead guard future-proofs
    against `-debug`-style suffixes — replacing the `\\b` boundary
    that would silently corrupt such a tag (hyphen is a word
    boundary for `\\b`)."""
    _seed_repo(tmp_path)
    (tmp_path / "Make" / "ci.mk").write_text(
        'NGINX_IMAGE="ghcr.io/magicsunday/webtrees-nginx:1.30-r1"\n'
        'NGINX_DEBUG_IMAGE="ghcr.io/magicsunday/webtrees-nginx:1.30-r1-debug"\n',
        encoding="utf-8",
    )
    rc = bumper.bump(tmp_path, "1.32")
    assert rc == 0
    body = (tmp_path / "Make" / "ci.mk").read_text(encoding="utf-8")
    assert "webtrees-nginx:1.32-r1" in body
    # The suffixed tag is left untouched.
    assert "webtrees-nginx:1.30-r1-debug" in body
    assert "webtrees-nginx:1.32-r1-debug" not in body


def test_main_argv_flag_before_positional(
    bumper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """`bump-nginx --config-revision 2 1.30` parses correctly (flag
    precedes positional)."""
    _seed_repo(tmp_path)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        sys, "argv", ["bump-nginx", "--config-revision", "2", "1.30"]
    )
    rc = bumper.main()
    assert rc == 0
    canonical = json.loads(
        (tmp_path / "dev" / "nginx-version.json").read_text(encoding="utf-8")
    )
    assert canonical == {"nginx_base": "1.30", "config_revision": 2, "tag": "1.30-r2"}


def test_main_argv_positional_before_flag_fails_loud(
    bumper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """`bump-nginx 1.31 --config-revision 2` (positional first) fails
    with the usage hint. The hand-rolled parser is order-sensitive;
    the usage hint says so explicitly."""
    monkeypatch.setattr(
        sys, "argv", ["bump-nginx", "1.31", "--config-revision", "2"]
    )
    rc = bumper.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "flags must precede the positional" in err


def test_script_is_executable_under_python3() -> None:
    """Smoke-execute the script as a subprocess so any syntax-level
    breakage surfaces at PR time rather than at maintenance time."""
    root = _resolve_repo_root()
    if root is None:
        pytest.skip("repo root not reachable")
    script = root / "scripts" / "bump-nginx.py"
    if not script.is_file():
        pytest.skip(f"bumper script missing: {script}")
    result = subprocess.run(
        [sys.executable, str(script)],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 2, (
        f"bumper script failed to parse / run: rc={result.returncode}, "
        f"stderr={result.stderr!r}"
    )
    assert "usage:" in result.stderr
