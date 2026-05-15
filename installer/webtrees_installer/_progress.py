"""Stage-by-stage progress reporter for the installer flow.

Issue #49: `curl … | bash` install runs silent through image pulls and
healthcheck-wait, so users wonder if the process wedged. This module
prints one stage line per major step (`[N/M] label …`), an elapsed-time
tick during long-running steps when polled, and a `✓ Xs` close-out when
the stage finishes (or `✘ Xs` when the stage raised).

Deliberately tiny — no spinner animation, no thread, no escape-sequence
clearing. Lines are append-only so CI logs and piped output stay
grep-able. Colour comes from the existing Term layer when the target
stream is a TTY without NO_COLOR.

Heartbeat cadence is `heartbeat_s` seconds (default 5) — caller overrides
the kwarg in tests + when wrapping a different poll loop.
"""

from __future__ import annotations

import time
from collections.abc import Iterator
from contextlib import contextmanager
from typing import IO

from webtrees_installer._term import Term


class ProgressReporter:
    """Emit `[N/M] label …` stage lines + elapsed-time ticks.

    Usage::

        progress = ProgressReporter(total=4, stream=stdout)

        with progress.stage("Rendering compose.yaml + .env"):
            render_files(...)

        with progress.stage("Bringing up the stack"):
            bring_up(progress=progress)   # tick() inside poll loop

    The context manager guarantees the close-out marker fires even when
    the wrapped block raises — failures get `✘ Xs` instead of `✓ Xs`, so
    a CI grep for `✓` counts only the successful stages.

    `stream=None` disables every print — tests use that to keep
    captured output deterministic.
    """

    # Minimum seconds between heartbeat ticks while a single stage runs.
    # 5s matches the issue's "activity at least every 10s" acceptance with
    # safety margin: even back-to-back slow poll loops won't go silent for
    # longer than two tick windows. Operator-tunable via the constructor's
    # `heartbeat_s` kwarg for tests that don't want to wait wall-clock.
    DEFAULT_HEARTBEAT_S: float = 5.0

    def __init__(
        self,
        *,
        total: int,
        stream: IO[str] | None,
        heartbeat_s: float = DEFAULT_HEARTBEAT_S,
    ) -> None:
        if total <= 0:
            raise ValueError(f"total must be > 0, got {total}")
        self._total = total
        self._stream = stream
        self._term = Term.for_stream(stream)
        self._heartbeat_s = heartbeat_s
        self._current = 0
        self._stage_start: float | None = None
        self._last_tick: float = 0.0

    @property
    def total(self) -> int:
        return self._total

    def start(self, label: str) -> None:
        """Open a new stage. Prints `[N/M] label …` to the stream."""
        self._current += 1
        if self._current > self._total:
            # Soft guard: an over-counted call would print `[5/4]` which
            # is a contract bug, but a hard raise here masks the real
            # failure mode (the calling flow proceeding past its planned
            # stages). Clamp + continue keeps user output consistent.
            self._current = self._total
        self._stage_start = time.monotonic()
        self._last_tick = self._stage_start
        if self._stream is not None:
            prefix = self._term.bold(f"[{self._current}/{self._total}]")
            print(f"{prefix} {label} …", file=self._stream, flush=True)

    def tick(self) -> None:
        """Emit `… Ns elapsed` if `heartbeat_s` has passed since the last
        tick or stage start. No-op when `stream` is None or no stage is
        active. Safe to call in a tight polling loop — internal throttle
        keeps output to one line per heartbeat window."""
        if self._stream is None or self._stage_start is None:
            return
        now = time.monotonic()
        if now - self._last_tick < self._heartbeat_s:
            return
        elapsed = int(now - self._stage_start)
        print(
            f"  {self._term.info(f'… {elapsed}s elapsed')}",
            file=self._stream,
            flush=True,
        )
        self._last_tick = now

    def finish(self, *, failed: bool = False) -> None:
        """Close the current stage and reset state for the next `start()`.

        Prints `✓ Xs` on success or `✘ Xs` on failure; the asymmetric
        marker lets a CI grep distinguish stages that ran clean from
        stages that raised. No-op when `stream` is None or no stage is
        active.
        """
        if self._stream is None or self._stage_start is None:
            return
        elapsed = int(time.monotonic() - self._stage_start)
        marker = self._term.error("✘") if failed else self._term.success("✓")
        print(
            f"  {marker} {elapsed}s",
            file=self._stream,
            flush=True,
        )
        self._stage_start = None

    @contextmanager
    def stage(self, label: str) -> Iterator["ProgressReporter"]:
        """Context-manager wrapper around `start` + `finish`.

        Guarantees the close-out marker is emitted whether the wrapped
        block succeeds or raises — a stage that raised gets ``✘ Xs`` so
        the operator sees the failure point and CI grep accounting stays
        sane. The exception is re-raised after the marker prints.
        """
        self.start(label)
        try:
            yield self
        except BaseException:
            self.finish(failed=True)
            raise
        else:
            self.finish()
