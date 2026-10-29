# Review Practices

Standards knightwatch-reviewer applies when reviewing PRs across the user's repos (plow, watchmepivot, code-config, etc.).

## Fail-Fast / Offensive Programming

See `CODING_STANDARDS.md` § Fail-Fast / Offensive Programming for the bullets.

## Tests

See `CLAUDE.md` § Tests and `TESTING.md` for canonical testing policy; `CODING_STANDARDS.md` § Tests for review-specific additions.

## Migrations

See `CODING_STANDARDS.md` § Migrations — never hand-write Alembic migrations; always `alembic revision --autogenerate` from model changes.

## Bot Findings, Cheap-First Review, and Visible Hooks

- **A bot finding that straddles code-bug vs product-decision → fix the *drift*, surface the product call.** When a finding sits between "this is a bug" and "this is a deliberate design choice", don't autonomously reverse the design, and don't ship the inconsistency either. Make the artifact internally honest about the deliberate contract (fix the drift), then surface the product call to the human. (Tell: a whole-PR re-review withheld the decline memory the aggregator needed — the move was to fix the drift and surface the product call, not to silently flip the design.)
- **Run cheap local review before expensive bot re-review.** Drain the free/local reviewer (roborev) at the push boundary — before each knightwatch re-trigger — never at the convergence gate. A local finding fixed *after* the cloud review converged moves the head and re-triggers a whole extra bakeoff for something the free reviewer surfaced rounds earlier; folded into the push that's already happening it costs zero extra rounds. Gate the expensive re-trigger on local-clean.
- **Install-time-wired hooks/daemons must print on the happy path, not only on findings — silence reads as "not installed."** A hook that emits nothing when it finds nothing is indistinguishable from a hook that never ran; print a one-line "ran, no findings" so the operator can tell it's live. (Tell: "I'm not seeing roborev messages — is it installed?" — the hook was silent on no-findings.)

## Concise Code

See `CODING_STANDARDS.md` § Concise Code for the bullets, plus § Broken-Glass Test § Subtractive remedies are higher-leverage than additive ones for the underlying principle.

## Approval Verdicts

- **Default verdict is APPROVE unless there are `medium` or `blocking` findings.** Low and nit findings appear in the review but do not prevent approval; `medium` and `blocking` both warrant `VERDICT: COMMENT`. Severity is exactly one of `blocking|medium|low|nit` — there is no `high`. The operative contract is the `VERDICT: COMMENT` trigger in knightwatch-reviewer `prompts/aggregator.md`, fenced by `lib/tests/prompt-contracts-smoke.sh`; restate it anywhere else only in agreement with that file.
- **Approving with nit/low findings worth noting → use the `pending:` form.** `VERDICT: APPROVE — pending: <item1>, <item2>` so the approval body communicates what minor things would be nice to clean up.

## Pre-Verdict Checklist

- **Before writing your verdict, for any PR that adds a new function, a new user-facing string, a fix scoped to a single input, or any single new block over ~20 LOC, run these checks inside the checked-out repo:**

  1. `grep` for near-duplicate function names and strings. Flag hits as *blocking: dry* with the existing path.
  2. For fixes scoped to one input, name the obvious next variant and check whether it's covered. If not, *medium: narrow-fix*.
  3. If the PR adds complexity to honor a spec detail verbatim, name a UX or contract change that would delete most of it. *low: spec-reframe*.

## Tooling: kid vs grep

- **Prior-art lookup runs via two paths depending on file type:**
  - **`*.py`** — semantic search via `kid` (indexes `~/Hacking/plow-kid`, injected into the review as a "PRIOR ART" section). Treat kid hits as leads, not verdicts: each match is either dismissed with a reason (different contract, unavoidable duplication) or raised as a DRY finding.
  - **`*.swift`, `*.ts`, `*.tsx`, everything else** — fall back to `grep` inside the checked-out repo for function names and near-duplicate strings (Pre-Verdict Checklist step 1). Kid Swift support is a planned follow-up; until then, do not assume kid covers Phoenix or frontend code.
- **Do not silently trust "no kid hits = DRY-clean".** Confirm whether the file went through `kid` semantic search or the `grep` fallback.

## Worked Example (DRY)

Bootup "warming up" status was previously reported in three places with divergent strings and logic. Unified to `RuntimeHeaderState.isWarmingUp` and one label in `app/Phoenix/ActivationState.swift`. A reviewer should have caught the third divergent copy on arrival. That is what "grep before you approve" looks like in practice.
