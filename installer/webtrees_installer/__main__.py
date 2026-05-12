"""Allow `python -m webtrees_installer` invocation."""

from webtrees_installer.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
