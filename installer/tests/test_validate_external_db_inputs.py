"""Tests for flow._validate_external_db_inputs.

The validator is the install-time gate that turns operator typos into
operator-actionable PromptErrors. Every failure mode the helper handles
gets one test so a refactor that drops a branch surfaces immediately,
and the test names double as the runbook for what the helper enforces.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from webtrees_installer.flow import (
    StandaloneArgs,
    _validate_external_db_inputs,
)
from webtrees_installer.prompts import PromptError


def _make_args(
    *,
    external_db_host: str | None = "db.internal",
    external_db_port: int = 3306,
    external_db_name: str = "webtrees",
    external_db_user: str = "webtrees",
    external_db_password_file: str | None = None,
) -> StandaloneArgs:
    """Factory: a baseline StandaloneArgs with use_external_db=True.

    Every test customises a single field via kwargs; the rest stay at
    sensible defaults so the test reads as 'change X, expect Y'.
    """
    return StandaloneArgs(
        work_dir=None,
        interactive=False,
        edition="core",
        proxy_mode="standalone",
        app_port=28080,
        domain=None,
        traefik_network="traefik",
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        demo=False,
        demo_seed=42,
        enforce_https=False,
        pretty_urls=False,
        force=True,
        no_up=True,
        use_external_db=True,
        external_db_host=external_db_host,
        external_db_port=external_db_port,
        external_db_name=external_db_name,
        external_db_user=external_db_user,
        external_db_password_file=external_db_password_file,
    )


def _write_password(tmp_path: Path, content: bytes, mode: int = 0o400) -> Path:
    """Write a password file with the given content + permission bits."""
    p = tmp_path / "db_password"
    p.write_bytes(content)
    p.chmod(mode)
    return p


def test_validator_accepts_well_formed_inputs(tmp_path: Path) -> None:
    """Happy path: every field valid, validator returns None without raising."""
    pw = _write_password(tmp_path, b"s3cret-pa55")
    args = _make_args(external_db_password_file=str(pw))
    _validate_external_db_inputs(args)


def test_validator_rejects_empty_host(tmp_path: Path) -> None:
    """An empty external_db_host short-circuits with the single-line fix."""
    pw = _write_password(tmp_path, b"x")
    args = _make_args(external_db_host="", external_db_password_file=str(pw))
    with pytest.raises(PromptError, match="--external-db-host"):
        _validate_external_db_inputs(args)


def test_validator_rejects_missing_password_file_arg() -> None:
    """`--use-external-db` without `--external-db-password-file` names the missing flag."""
    args = _make_args(external_db_password_file=None)
    with pytest.raises(PromptError, match="--external-db-password-file"):
        _validate_external_db_inputs(args)


def test_validator_rejects_nonexistent_password_path(tmp_path: Path) -> None:
    """A path that does not exist surfaces with the actual path quoted back."""
    missing = tmp_path / "does-not-exist"
    args = _make_args(external_db_password_file=str(missing))
    with pytest.raises(PromptError, match="does not exist"):
        _validate_external_db_inputs(args)


def test_validator_rejects_empty_password_file(tmp_path: Path) -> None:
    """A zero-byte password file is the silent-no-password trap; reject loud."""
    pw = _write_password(tmp_path, b"")
    args = _make_args(external_db_password_file=str(pw))
    with pytest.raises(PromptError, match="is empty"):
        _validate_external_db_inputs(args)


def test_validator_rejects_trailing_newline_password(tmp_path: Path) -> None:
    """A `\\n`-only file passes size>0 but fails MariaDB auth — strip-check rejects it."""
    pw = _write_password(tmp_path, b"\n")
    args = _make_args(external_db_password_file=str(pw))
    with pytest.raises(PromptError, match="whitespace"):
        _validate_external_db_inputs(args)


def test_validator_rejects_password_with_trailing_newline_from_echo(tmp_path: Path) -> None:
    """`echo 's3cret' > file` produces 's3cret\\n' — common operator mistake."""
    pw = _write_password(tmp_path, b"s3cret\n")
    args = _make_args(external_db_password_file=str(pw))
    with pytest.raises(PromptError, match="whitespace"):
        _validate_external_db_inputs(args)


def test_validator_rejects_password_with_leading_whitespace(tmp_path: Path) -> None:
    """Leading whitespace is just as fatal as trailing; reject symmetrically."""
    pw = _write_password(tmp_path, b" s3cret")
    args = _make_args(external_db_password_file=str(pw))
    with pytest.raises(PromptError, match="whitespace"):
        _validate_external_db_inputs(args)


def test_validator_rejects_out_of_range_port(tmp_path: Path) -> None:
    """argparse type=int accepts 99999; the validator must catch the range."""
    pw = _write_password(tmp_path, b"x")
    args = _make_args(
        external_db_port=99999, external_db_password_file=str(pw),
    )
    with pytest.raises(PromptError, match="out of range"):
        _validate_external_db_inputs(args)


def test_validator_rejects_zero_port(tmp_path: Path) -> None:
    """Port 0 is a valid integer but a meaningless target."""
    pw = _write_password(tmp_path, b"x")
    args = _make_args(external_db_port=0, external_db_password_file=str(pw))
    with pytest.raises(PromptError, match="out of range"):
        _validate_external_db_inputs(args)


@pytest.mark.parametrize(
    "field,value,label",
    [
        ("external_db_host", "host name with space", "--external-db-host"),
        ("external_db_host", "host;rm -rf /", "--external-db-host"),
        ("external_db_user", "user with quote'", "--external-db-user"),
        ("external_db_name", "name=with-equals", "--external-db-name"),
        ("external_db_name", "name$with-dollar", "--external-db-name"),
        ("external_db_user", "", "--external-db-user"),
    ],
)
def test_validator_rejects_identifier_with_unsafe_characters(
    tmp_path: Path, field: str, value: str, label: str,
) -> None:
    """Whitespace, quotes, ';', '=', '$', empty strings all corrupt the
    rendered .env or the compose YAML substitution. The validator rejects
    them all with a message naming the offending flag."""
    pw = _write_password(tmp_path, b"x")
    kwargs = {"external_db_password_file": str(pw), field: value}
    args = _make_args(**kwargs)
    with pytest.raises(PromptError, match=label):
        _validate_external_db_inputs(args)


def test_validator_warns_on_world_readable_password_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    """Mode 0644 is operator-choice, not fatal — but a warning routes to stderr."""
    pw = _write_password(tmp_path, b"s3cret", mode=0o644)
    args = _make_args(external_db_password_file=str(pw))
    _validate_external_db_inputs(args)  # must NOT raise

    captured = capsys.readouterr()
    assert "0644" in captured.err
    assert "chmod 0400" in captured.err


def test_validator_silent_on_tightly_permissioned_password_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    """Mode 0400 is the docs-recommended posture; no warning emitted."""
    pw = _write_password(tmp_path, b"s3cret", mode=0o400)
    args = _make_args(external_db_password_file=str(pw))
    _validate_external_db_inputs(args)

    captured = capsys.readouterr()
    assert "0400" not in captured.err
    assert captured.err == ""


@pytest.mark.parametrize("port", [1, 3306, 65535])
def test_validator_accepts_port_boundaries(tmp_path: Path, port: int) -> None:
    """Port range is inclusive on both ends — pin the boundaries so a
    refactor that flips the comparison to `<` instead of `<=` fails loud."""
    pw = _write_password(tmp_path, b"x")
    args = _make_args(external_db_port=port, external_db_password_file=str(pw))
    _validate_external_db_inputs(args)


@pytest.mark.parametrize(
    "host",
    [
        "fd00::1",
        "[fd00::1]",
        "fe80::1%eth0",
        "192.168.1.1",
        "db.internal",
        "mariadb-01",
    ],
)
def test_validator_accepts_ipv4_ipv6_and_dns_hosts(
    tmp_path: Path, host: str,
) -> None:
    """IPv6 literals are common for modern self-hosters; the host regex
    must accept colons + brackets + zone-suffix percent without the
    .env-corruption gate firing."""
    pw = _write_password(tmp_path, b"x")
    args = _make_args(external_db_host=host, external_db_password_file=str(pw))
    _validate_external_db_inputs(args)
