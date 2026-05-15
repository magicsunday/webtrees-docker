"""Unit tests for webtrees_installer._progress."""

from __future__ import annotations

import io
import time
from typing import IO
from unittest import mock

import pytest

from webtrees_installer._progress import ProgressReporter


def _no_color_env() -> mock._patch[dict[str, str]]:
    import os
    env = {k: v for k, v in os.environ.items() if k != "NO_COLOR"}
    return mock.patch.dict(os.environ, env, clear=True)


# ---------------------------------------------------------------- construction


def test_rejects_zero_total() -> None:
    with pytest.raises(ValueError, match="total must be > 0"):
        ProgressReporter(total=0, stream=io.StringIO())


def test_rejects_negative_total() -> None:
    with pytest.raises(ValueError, match="total must be > 0"):
        ProgressReporter(total=-1, stream=io.StringIO())


# ---------------------------------------------------------------- stream None


def test_stream_none_swallows_every_call() -> None:
    """A None stream silently no-ops — tests + autouse harness use this
    to keep captured output deterministic."""
    p = ProgressReporter(total=3, stream=None)
    p.start("alpha")
    p.tick()
    p.finish()
    # No assertions on output (there is none); the contract is
    # 'doesn't raise + doesn't crash.'


# ---------------------------------------------------------------- stage lines


def test_start_emits_prefix_and_label_to_stream() -> None:
    out: IO[str] = io.StringIO()
    with _no_color_env():  # StringIO is not a TTY → colour disabled regardless
        p = ProgressReporter(total=2, stream=out)
        p.start("Rendering compose.yaml + .env")
    body = out.getvalue()
    assert "[1/2]" in body
    assert "Rendering compose.yaml + .env" in body
    assert body.endswith("…\n") or body.endswith("…\r\n")


def test_consecutive_starts_increment_the_index() -> None:
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=3, stream=out)
    p.start("step one")
    p.start("step two")
    p.start("step three")
    body = out.getvalue()
    assert "[1/3]" in body
    assert "[2/3]" in body
    assert "[3/3]" in body


def test_overcounting_clamps_to_total_rather_than_overflow() -> None:
    """Calling start() more than `total` times must not print [N+1/N] —
    the calling flow has a contract bug, but the user-visible output
    should stay consistent."""
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    p.start("first")
    p.start("second-bug")
    body = out.getvalue()
    assert "[1/1]" in body
    assert "[2/1]" not in body  # never overflows


# ---------------------------------------------------------------- finish


def test_finish_emits_elapsed_seconds() -> None:
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    p.start("work")
    p.finish()
    body = out.getvalue()
    # Elapsed is monotonic-time-based; on a fast test machine it's 0s.
    assert "✓ 0s" in body or "✓ 1s" in body


def test_finish_without_start_is_noop() -> None:
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    p.finish()
    assert out.getvalue() == ""


def test_finish_resets_state_for_next_start() -> None:
    """After finish() the reporter must accept a fresh start() — no
    leaked elapsed time, no double-counting of the index."""
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=2, stream=out)
    p.start("first")
    p.finish()
    p.start("second")
    body = out.getvalue()
    assert "[1/2]" in body
    assert "[2/2]" in body


# ---------------------------------------------------------------- heartbeat


def test_tick_within_heartbeat_window_is_silent() -> None:
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out, heartbeat_s=10.0)
    p.start("slow")
    pre_len = len(out.getvalue())
    p.tick()
    p.tick()
    p.tick()
    # No tick output should have been emitted; tick() respects the
    # 10s throttle.
    assert len(out.getvalue()) == pre_len


def test_tick_after_heartbeat_window_emits_elapsed_line() -> None:
    """Patch time.monotonic on the imported `time` module so _progress
    (which does `import time; time.monotonic()` — attribute-lookup at
    call time) and the test see the same patched callable. A
    string-form `mock.patch('time.monotonic')` would NOT work because
    it'd resolve against the test module's namespace instead."""
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out, heartbeat_s=5.0)

    times = iter([100.0, 107.0])
    with mock.patch.object(time, "monotonic", lambda: next(times)):
        p.start("slow")  # consumes 100.0
        p.tick()         # consumes 107.0 → 7s elapsed, ≥ 5s window
    body = out.getvalue()
    assert "… 7s elapsed" in body


def test_tick_without_active_stage_is_noop() -> None:
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    p.tick()
    assert out.getvalue() == ""


def test_tick_with_stream_none_is_noop() -> None:
    p = ProgressReporter(total=1, stream=None)
    p.start("anything")
    p.tick()  # must not raise even though _start was recorded


# ---------------------------------------------------------------- colour gate


def test_disabled_term_strips_ansi_from_stage_line() -> None:
    """StringIO is non-TTY → Term returns plain text; the printed line
    must carry no ANSI escapes (CI-log readability)."""
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=2, stream=out)
    p.start("plain step")
    p.finish()
    body = out.getvalue()
    assert "\033[" not in body, f"unexpected ANSI in non-TTY output: {body!r}"


def test_total_property_exposes_constructor_value() -> None:
    p = ProgressReporter(total=7, stream=None)
    assert p.total == 7


# ---------------------------------------------------------------- context-mgr


def test_stage_context_manager_emits_start_and_finish() -> None:
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    with p.stage("work"):
        pass
    body = out.getvalue()
    assert "[1/1] work …" in body
    assert "✓ " in body


def test_stage_context_manager_marks_failed_with_x_on_exception() -> None:
    """A stage that raised must close with ✘ Xs (not ✓), so an operator
    or CI grep can distinguish 'all stages green' from 'crashed mid-way'.
    The exception itself must propagate; the marker is just a paper trail."""
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    with pytest.raises(RuntimeError, match="boom"):
        with p.stage("crashing-stage"):
            raise RuntimeError("boom")
    body = out.getvalue()
    assert "[1/1] crashing-stage …" in body
    assert "✘ " in body
    assert "✓ " not in body  # never confusing-marker on a failure


def test_stage_context_manager_propagates_keyboard_interrupt() -> None:
    """BaseException subclasses (KeyboardInterrupt, SystemExit) must
    propagate too — `except Exception` here would silently swallow the
    operator's Ctrl-C."""
    out: IO[str] = io.StringIO()
    p = ProgressReporter(total=1, stream=out)
    with pytest.raises(KeyboardInterrupt):
        with p.stage("interrupted"):
            raise KeyboardInterrupt()
    body = out.getvalue()
    assert "✘ " in body
