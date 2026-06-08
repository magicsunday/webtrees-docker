"""Allow `python -m webtrees_installer` invocation."""

from __future__ import annotations

from webtrees_installer.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
