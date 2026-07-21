# Contributing to webtrees-docker

This document codifies the standards every contributor — human or
coding agent — must follow when changing this repository. It is the
single source of truth for the project's design-principle order, the
specific code conventions, and the audit-loop discipline.

For project layout and recent footguns, also read
[`AGENTS.md`](AGENTS.md). For self-host instructions read
[`README.md`](README.md). For maintainer workflows read
[`docs/developing.md`](docs/developing.md).

## Design-principle order

When two principles conflict, apply this priority — the higher entry
wins:

1. **KISS** — Keep it simple. Three similar lines beat a premature
   abstraction. Don't introduce indirection until you have ≥3 concrete
   call sites and the shared payload is non-trivial.
2. **SOLID** — Single Responsibility, Open/Closed, Liskov,
   Interface Segregation, Dependency Inversion. Applies when an
   abstraction is justified by KISS; not a reason to introduce one.
3. **DRY** — Don't repeat yourself. Apply only AFTER the abstraction
   cost has been paid; before then, KISS wins. Two near-identical
   blocks are usually fine; three start asking for extraction.
4. **YAGNI** — You aren't gonna need it. No features, flags, or
   hooks for hypothetical futures. No "while we're here" cleanup
   beyond what the task requires.
5. **GRASP** — General Responsibility Assignment Software Patterns.
   Information Expert, Creator, Controller, Low Coupling, High
   Cohesion. Decides WHICH object owns a responsibility when SOLID
   alone doesn't.
6. **Law of Demeter** — Talk only to immediate collaborators. No
   `obj.foo.bar.baz` chains across module boundaries.
7. **Separation of Concerns** — One module, one reason to change.
8. **Convention over Configuration** — Match existing patterns
   unless there's a clear reason to deviate. Surprise the reader at
   your peril.

A change that violates a lower-priority principle to satisfy a
higher-priority one is correct by definition. Document the trade-off
in the commit message if it is non-obvious.

## Repo conventions

### Shell

- `set -euo pipefail` (or the long form `set -o errexit -o nounset
  -o pipefail`) at the top of every script.
- `grep -q` inside a pipefail pipeline SIGPIPEs the upstream and trips
  pipefail. Either feed via `<<<` here-string, or capture into a
  variable with `out=$(cmd) || exit 1` and operate on `"$out"`. The
  captured-variable form additionally surfaces the upstream exit
  status that the pipefail-vs-`if` shape silently swallows, and the
  same pattern generalises to any first-match early-exit command
  (`head`, `awk … exit`, `sed -n …q`).
- Quote every variable expansion (`"$var"`) unless intentional
  word-splitting is documented inline.
- `${var:-default}` for safe defaulting; bare `$var` under `set -u`
  aborts the script.
- Centralised CI tooling images: every `docker run` against a
  standalone image (python, jq, hadolint, shellcheck, yamllint) goes
  through `$(CI_RUN_*)` in `Make/images.mk` or `ci_run_jq` /
  `ci_run_jq_stdin` in `scripts/lib/images.env`. Direct `docker run
  --rm` is reserved for entries that don't yet have a wrapper.

### Python

- `from __future__ import annotations` at the top of every module.
- Type-hint every function signature; `mypy --strict`-clean.
- Explicit `except (TypeA, TypeB) as exc:` tuples; never bare `except:`.
- `%0A` newline-encode multi-line `::error::` GHA annotations:
  `f"::error::line1%0Aline2"`.
- Stub external collaborators in tests (subprocess, network, docker),
  not the helper under test. An autouse fixture that mocks the very
  function being asserted hides every failure path.

### Makefile

- Recipes wrap compose-services via `$(COMPOSE_BUILD)` /
  `$(COMPOSE_BUILD_ROOT)` / `$(COMPOSE_BUILD_COMPOSER)`. Standalone
  CI tooling images go through `$(CI_RUN_*)` from `Make/images.mk`.
- Hand-rolled `docker run` in a recipe is a smell — propose a wrapper
  in `Make/images.mk` instead.
- Help text via `## …` on the same line as the target name; the
  `make help` parser reads it directly.

### GitHub workflows

- Interpolation: `${{ ... }}` expressions go through an `env:` step
  scope, never directly into a `run: |` scalar. Direct interpolation
  is a shell-injection vector when the value is user-controlled.
- Lockstep contracts: every drift-prone literal (alpine pin, port
  default, badge URL, image digest) gets a `ci-*-lockstep` Make target
  and a failure-path test in `tests/test-lockstep.sh` that injects the
  violation.
- Single source of truth: when N files reference the same value, name
  one canonical and grep-verify the rest from a Make-driven check.

### Tests

- Behaviour-asserting, not vacuous. No getter/setter tests. No
  coverage-only tests without a behavioural assertion.
- Tests that stub the helper they assert teach you nothing; stub
  external collaborators instead.
- Failure-path tests: every lockstep needs at least one test that
  injects the violation it claims to guard against, otherwise a future
  regex weakening passes silently.

### Comments

- WHY, not WHAT. Well-named identifiers cover WHAT. Use comments for
  hidden constraints, non-obvious invariants, workarounds for specific
  bugs, surprising behaviour.
- No references to prior states ("matches the legacy chart", "as
  before", "same as the old code"). Once the prior state is gone, the
  comment rots.
- No third-party project references in repo artefacts (issues,
  commits, comments, docs). Describe in absolute terms — what THIS
  code does, not what some other project does.
- No audit-round labels in committed comments ("R10/R11 fix", "after
  review round 3"). Audit rounds are session-local; the comment
  outlives them.
- All code comments in English. Planning docs and conversation may be
  in any language.
- PHPDoc / TSDoc / docstring descriptions start with a capital letter
  and describe intent, not mechanics.

### Frontmatter and metadata

- Issue / PR titles in absolute terms: `Probe Windows host IP under
  WSL2`, not `Like NathanVaughn does it`.
- Commit subjects — and the pull-request title — are governed by the shared `commit-convention` gate; the normative rule and its full rationale live in `magicsunday/.github/.github/workflows/commit-convention.yml@main`, which self-tests a decision table before applying it. In short: a `GH-`-prefixed subject must match `^GH-\d+: [A-Z]`, every other subject `^[A-Z]` — a capitalised English imperative — and conventional-commit prefixes (`feat:`, `Fix:`, …) as well as path-like starts (`src/…: …`) are rejected whatever their case. It runs on every pull request via `.github/workflows/commit-lint.yml`, advisory until `commit-convention / Commit convention` is a required context in branch protection.
- Branches for an issue are named exactly `GH-<N>`; the `GH-<N>: ` prefix marks work that belongs to that issue, so a drive-by fix on the branch keeps its own unprefixed subject.
- The pull-request body closes the issue with `Closes #<N>` — the `GH-<N>: ` subject prefix is not a GitHub link and closes nothing.
- Never add a `Co-Authored-By:` trailer or any other AI attribution.

## Audit-loop discipline

Every non-trivial change goes through an audit loop before commit:

1. **Spawn all relevant reviewers in parallel**, not just the
   always-on ones. Conditional reviewers (adversarial / security /
   reliability / performance / language-specific / data-migrations /
   API-contract / previous-comments) fire whenever their triggers
   match the diff.
2. **2× consecutive clean rounds** before commit. One clean round
   may have missed something the next round catches; two cleans is
   the discipline. *Why two*: a single clean round can succeed merely
   because the reviewer agreed with itself — a fresh second round
   catches what the first one rationalised past.
3. **Anchor threshold**: findings with confidence ≥50 are blockers
   and must be addressed in-session. Findings <50 are residual risks,
   documented but not necessarily fixed. *Why 50*: below that,
   reasonable reviewers disagree on whether the issue is real;
   forcing changes for sub-50 findings inflates the diff without
   raising the quality floor.
4. **Bug-class sweep**: before applying a point fix, `grep` for the
   pattern repo-wide. A single occurrence usually means N other
   occurrences nobody noticed yet. *Why*: shipping a point fix
   while five identical bugs remain in-tree is the regression
   pattern the audit-loop exists to prevent.
5. **Smaller diffs**: aim for ≤300 LoC per commit. Bigger refactors
   split into atomic commits — each independently reviewable and
   revertable. *Why 300*: reviewer attention measurably drops past
   that mark, and a future bisect against an atomic commit is
   strictly cheaper than against a multi-concern blob.
6. **No preexisting excuse**: every defect found during verification
   gets fixed in-session, never dismissed as "preexisting" or "not my
   change".
7. **Local CI green before push**: `make ci-test` exits 0 before any
   commit lands on main. The local pipeline mirrors what CI runs.
8. **One commit per finished task**: when a task wraps up and is
   verified green, commit it. Don't batch into end-of-session dumps.

After every commit, run a code review on it before starting the next
task. The audit-loop scope is the original task baseline, not just
the latest patch diff.

## Cross-references

- [`AGENTS.md`](AGENTS.md) — repo layout + time-bounded traps.
- [`README.md`](README.md) — self-host install instructions.
- [`docs/developing.md`](docs/developing.md) — maintainer workflows.
- [`docs/env-vars.md`](docs/env-vars.md) — every environment variable
  the wizard and runtime consume.
- [`docs/https-certs.md`](docs/https-certs.md) — TLS / cert
  troubleshooting (including the `ci-tls-verify-lockstep` scope note).
