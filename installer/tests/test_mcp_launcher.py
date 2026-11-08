"""Regression guard for the Playwright MCP launcher in `.mcp.json`.

The launcher reads the CDP endpoint of the dev `browser` service and hands it
to the Playwright MCP server. The dev stack serves a self-signed certificate,
so the endpoint has to carry the `ignoreHTTPSErrors=true` opt-in for the MCP
server to open the dev site. This test runs the launcher command with stubbed
`curl` and `npx` and asserts the endpoint it passes on.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest


def _resolve_repo_root() -> Path | None:
    """Same precedence as the lockstep tests: `WT_REPO_ROOT` first, then the
    checkout the test file lives in."""
    env_root = os.environ.get("WT_REPO_ROOT")
    if env_root:
        return Path(env_root)
    try:
        return Path(__file__).resolve().parents[2]
    except IndexError:
        return None


@pytest.mark.parametrize(
    ("reported_url", "expected_netloc", "expected_query"),
    [
        pytest.param(
            "ws://0.0.0.0:3000/",
            "0.0.0.0:3000",
            {"ignoreHTTPSErrors": ["true"]},
            id="no-query",
        ),
        pytest.param(
            "ws://0.0.0.0:3000/?token=abc",
            "0.0.0.0:3000",
            {"token": ["abc"], "ignoreHTTPSErrors": ["true"]},
            id="existing-query",
        ),
    ],
)
def test_launcher_passes_the_certificate_opt_in_in_the_cdp_endpoint(
    tmp_path: Path,
    reported_url: str,
    expected_netloc: str,
    expected_query: dict[str, list[str]],
) -> None:
    """The launcher hands the CDP endpoint to Playwright with the opt-in,
    whether or not the reported debugger URL already carries a query."""
    root = _resolve_repo_root()
    if root is None or not (root / ".mcp.json").is_file():
        pytest.skip("repository root with .mcp.json is not reachable")

    config = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
    command = config["mcpServers"]["playwright"]["args"][-1]

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    argv_file = tmp_path / "npx-argv"
    (bin_dir / "curl").write_text(
        "#!/bin/sh\n"
        f"printf '%s' '{{\"webSocketDebuggerUrl\": \"{reported_url}\"}}'\n",
        encoding="utf-8",
    )
    (bin_dir / "npx").write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' \"$@\" > \"$ARGV_FILE\"\n",
        encoding="utf-8",
    )
    for stub in (bin_dir / "curl", bin_dir / "npx"):
        stub.chmod(0o755)

    result = subprocess.run(
        ["bash", "-c", command],
        env={
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "ARGV_FILE": str(argv_file),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    argv = argv_file.read_text(encoding="utf-8").splitlines()
    endpoint = urlsplit(argv[argv.index("--cdp-endpoint") + 1])
    assert (endpoint.scheme, endpoint.netloc) == ("ws", expected_netloc)
    assert parse_qs(endpoint.query) == expected_query
