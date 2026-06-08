"""Shared filesystem helpers for the wizard.

Kept tiny on purpose: the two renderers (`render.py` for compose+env in
standalone mode, `dev_flow.py` for the dev `.env`) share the same
"never leave a half-written file in /work" contract, and the only way
to keep them aligned is to make them call the same helper.
"""

from __future__ import annotations

from pathlib import Path


def atomic_write(path: Path, content: str) -> None:
    """Write content to path via a sibling .tmp file + os.replace swap.

    A Ctrl-C between `Path.write_text` and `Path.replace` leaves the
    half-written content in `<path>.tmp`, not at `<path>` itself, so a
    follow-up `docker compose ...` always sees either the prior good
    file or the fully-rendered new one.
    """
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content)
    tmp.replace(path)


def atomic_write_all(files: list[tuple[Path, str]]) -> None:
    """Write several files with the smallest practical cross-file window.

    Every temp file is written first; only then do the ``Path.replace``
    swaps run back-to-back with no rendering / I/O in between. That shrinks
    the interruption window to the gap between bare ``rename(2)`` syscalls,
    instead of the much wider window left by N separate ``atomic_write``
    calls (each of which wrote its temp file just before swapping it).

    This is NOT true cross-file atomicity — a crash between two
    ``replace`` calls can still leave file A swapped and file B not, which
    no POSIX primitive prevents without a transactional filesystem. It is
    the practical minimum, and the only honest guarantee the renderers can
    make about their multi-file output.
    """
    staged: list[tuple[Path, Path]] = []
    for path, content in files:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(content)
        staged.append((tmp, path))
    for tmp, path in staged:
        tmp.replace(path)
