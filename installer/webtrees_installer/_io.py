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
