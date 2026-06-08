"""Tests for the shared atomic-write helpers.

The whole reason `_io` exists is the crash-safety contract: a follow-up
`docker compose ...` must never see a half-written file. These tests pin
that contract directly instead of relying on the renderers' indirect
coverage.
"""

from __future__ import annotations

import pathlib
from pathlib import Path

import pytest

from webtrees_installer._io import atomic_write, atomic_write_all


def test_atomic_write_creates_file(tmp_path: Path) -> None:
    target = tmp_path / "out.txt"
    atomic_write(target, "hello")
    assert target.read_text() == "hello"
    # The sibling temp must not linger after a successful swap.
    assert not (tmp_path / "out.txt.tmp").exists()


def test_atomic_write_replace_failure_preserves_original(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """If the rename swap fails, the prior good file is left untouched."""
    target = tmp_path / "out.txt"
    target.write_text("ORIGINAL")

    real_replace = pathlib.Path.replace

    def boom(self: Path, *args: object, **kwargs: object) -> Path:
        if self.name == "out.txt.tmp":
            raise OSError("simulated rename failure")
        return real_replace(self, *args, **kwargs)

    monkeypatch.setattr(pathlib.Path, "replace", boom)

    with pytest.raises(OSError, match="simulated rename failure"):
        atomic_write(target, "NEW")

    # The target keeps the prior content; the partial write sits in .tmp.
    assert target.read_text() == "ORIGINAL"


def test_atomic_write_all_writes_every_file(tmp_path: Path) -> None:
    files = [
        (tmp_path / "compose.yaml", "compose"),
        (tmp_path / ".env", "env"),
        (tmp_path / "Makefile", "make"),
    ]
    atomic_write_all(files)
    assert (tmp_path / "compose.yaml").read_text() == "compose"
    assert (tmp_path / ".env").read_text() == "env"
    assert (tmp_path / "Makefile").read_text() == "make"
    for path, _ in files:
        assert not path.with_suffix(path.suffix + ".tmp").exists()


def test_atomic_write_all_writes_all_temps_before_any_swap(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failure writing the 2nd temp must leave EVERY target unswapped.

    This is the discriminator between the new "write all temps, then swap
    all" ordering and the old "write+swap per file" loop: if the first
    file had already been swapped when the second write fails, the first
    original would be clobbered. Seed three originals, blow up on the
    second temp write, and assert all three originals survive intact.
    """
    a = tmp_path / "compose.yaml"
    b = tmp_path / ".env"
    c = tmp_path / "Makefile"
    a.write_text("ORIG-A")
    b.write_text("ORIG-B")
    c.write_text("ORIG-C")

    real_write_text = pathlib.Path.write_text

    def boom(self: Path, *args: object, **kwargs: object) -> int:
        if self.name == ".env.tmp":
            raise OSError("simulated write failure")
        return real_write_text(self, *args, **kwargs)

    monkeypatch.setattr(pathlib.Path, "write_text", boom)

    with pytest.raises(OSError, match="simulated write failure"):
        atomic_write_all([(a, "NEW-A"), (b, "NEW-B"), (c, "NEW-C")])

    assert a.read_text() == "ORIG-A"
    assert b.read_text() == "ORIG-B"
    assert c.read_text() == "ORIG-C"
