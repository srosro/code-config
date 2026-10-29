# Authoring (Before You Code)

The goal is to extend the codebase's existing seams, not to add parallel ones. These habits before writing prevent the most common LLM/agent failure modes — building the wrong thing well, parallel patterns, half-migrated state, and confidently-wrong "new" abstractions.

## Know what the project is currently driving at

- **Read the repo's root `REVIEW.md` before you write code.** It carries the operating point and the **current thrust** — what this codebase is being pushed toward right now, and what it is deliberately deferring. That single fact decides most of the judgment calls downstream: whether a security hardening is the point or a distraction, whether a defensive branch earns its keep, how a finding should be graded when you file it.
- **If the repo's `REVIEW.md` carries no current thrust — or it reads as stale — ask the operator, and record the answer there.** One question up front is cheap; the alternative is a session's worth of work weighted against a goal nobody holds. It also sets the *reviewer's* posture: `REVIEW.md` is inlined into roborev's `review_guidelines` and read by knightwatch, so an unstated thrust means both reviewers grade every PR against a default that may not be yours. Don't infer a thrust from the code and write it down as fact — an inferred goal is the operator's to confirm.

## Plan first for anything non-trivial

- **Invoke `/superpowers:writing-plans` before touching code for changes >25 LOC, multi-file, or of any moderate complexity** (anything you can't hold in your head end-to-end as you type). The plan forces you to:
  - Name the class of problem first (parsing, dispatch, state, retry, validation, config, ...)
  - Look for the existing seam in this codebase that handles that class
  - Decide explicitly: extend the seam, or have a real reason for adding a new one
  - **For any change touching state, lifecycle, or infrastructure: include an Ownership census block** — one line per lifecycle event, `concern/event → owner(s) today → owner after` (row-keying semantics + worked example: `CODING_STANDARDS.md` § Ownership Census). A row with multiple owners → resolve it per that section before any task builds on either path. This block is what makes the plan a design artifact rather than a task list (the `plow#1041` plan documented a second VM-recreation owner in its own prose and still scripted machinery onto the first).
- **Trivial changes (typos, single-method tweaks, adding a log line) don't need a plan.** Every non-trivial change gets one. The cost of writing a plan is small; the cost of writing the wrong code is N rounds of bot review and a refactor PR.

## Strangler fig when replacing existing functionality

- **When migrating, refactoring, or replacing existing code, strangler fig:** build the new path alongside the old one and route call sites to it incrementally, rather than swapping in one big-bang change.
  - Each migrated call site is its own commit, reviewable in isolation.
  - The codebase stays green throughout — no half-migrated state where some callers use new and others use old.
  - The old code gets deleted in the **final** commit, after every call site has moved.
- **Strangler fig applies to API redesigns, library swaps, schema migrations that touch code, and any "replace pattern X with pattern Y" task.** Big-bang rewrites tend to land with bugs hidden in the moved-but-untouched code that the diff makes hard to see.
- **Greenfield code (no existing implementation to replace) doesn't need this** — strangler fig is specifically for replacement.

## Be skeptical of any change >10 LOC

- **Once a change exceeds ~10 LOC in a single block, pause and run this section's question list before continuing.**
- **Is this file's destiny on a sibling branch?** Run `git log --all -- <file>` and `gh pr list --search "<file>" --json title,state,mergeable` before investing in non-trivial work on it. An unmerged commit or open MERGEABLE PR that deletes or restructures the file changes the cost calculus — additive remedies you ship here may be dead-on-arrival. If the file is scheduled for removal, prefer declining additive findings in the current PR and surfacing the in-flight PR# in the reply; let the other work retire the surface. Worked example: `plow-pbc/plow#680` declined a `[blocking]` worktree-isolation probe on `chat/compose.yaml` because `plow-pbc/plow#638` (MERGEABLE) was deleting the file plus all 11 `chat/tests/test_*.py` files; investing 15-25 LOC of slot-port infra would have been dead-on-arrival.
- **Is this DRY?** Grep the repo for similar logic. Is the same shape already solved elsewhere? If yes, unify rather than adding a parallel implementation. Parallel implementations are the single most common LLM defect — they look fine in review and calcify tech debt.
- **Is this the right pattern?** Does an existing seam in this codebase already handle this class of problem? Common seams to look for: config helper, persistence/repository layer, HTTP client wrapper, retry decorator, error-envelope mapper, dispatch registry, validation schema, state enum, logger/metrics, auth middleware, feature flag client. If yes, extend that seam.
- **If you're inventing a "new" pattern, be VERY skeptical.** Most codebases already have patterns for most things. A "new" pattern is almost always either (i) the codebase's existing pattern you missed because you didn't grep, or (ii) a parallel pattern that contradicts an existing one and calcifies as tech debt. Bias hard toward "I missed something" before concluding the pattern doesn't exist.
- **How many owners does this lifecycle event have?** If the block adds guards, fallbacks, tests, or explanatory comments to a code path, first count the paths that own the same lifecycle event (who else recreates this? who else stops it?). More than one → `CODING_STANDARDS.md` § Ownership Census before proceeding.
- **Is the upstream feature actually shipped?** If the design depends on a third-party library, framework, or service feature, verify it is shipped in the exact runtime you will use: a tagged release for libraries/frameworks, or official release notes/docs (or an enabled account capability) for services. Repo docs and design specs name features that aren't merged. PR #627 burned 3 rounds designing around an OpenClaw cron mode that PR #51276 had closed upstream.
- **10 LOC isn't a hard rule — it's a trigger for this section's questions.** A 50-LOC change that extends an existing seam cleanly is fine; a 12-LOC change that invents a one-off pattern next to an existing one is not. The questions are the point.

## A tool's agent-facing contract normally ships with its installer

- **A tool's usage contract ships from the tool's seed as an installed skill** (`~/.claude/skills/<tool>/SKILL.md`), **not** hand-written into code-config's `CLAUDE.md`. When a tool/daemon you install needs the agent to know *how to use it* (its commands, its review/commit loop, its gotchas), code-config keeps only the tool-*independent* rule (e.g. "commit often" stands with or without the tool) plus at most a thin pointer.
- **Roborev's frozen installer is the explicit exception:** code-config owns its Claude hooks and skill; the compatibility installer owns only the binary, daemon, and native Git hooks.
- **Bright line:** if an instruction only makes sense when the tool is installed, it belongs in the seed skill — so a fresh-machine seed install delivers mechanism *and* understanding in one shot. `~/.claude/skills/` preserves user-owned (seed-installed) entries on `just install`, so the two coexist.
- **Before adding a consumer-side "remember to do X" instruction, check whether the seed already ships a FORCING FUNCTION** (a PreToolUse hook/gate) that enforces it — a gate beats prose, and the consumer-side restatement is pure drift surface. And don't build a new wrapper command for what existing commands already compose — the fix is usually a few lines of policy in the seed's existing skill, with consumers *referencing* it.
- **Seed-backed tooling normally deploys via its seed:** a fleet rollout is `/seed-install <seed.git>` re-run per machine. Roborev's Claude layer instead deploys with code-config; its compatibility installer supplies the binary, daemon, and native Git hooks.

## See also

- `CODING_STANDARDS.md` § Name the Shape — the canonical version of the pattern-conformance principle the questions in § Be skeptical of any change >10 LOC enforce.
- `CODING_STANDARDS.md` § DRY: Find Existing Logic Before Adding New — the canonical DRY principle.
- `PR_LIFECYCLE.md` — what happens after the code is written (handling bot reviews).
- `superpowers:writing-plans` — the planning skill referenced in § Plan first for anything non-trivial. Use via `/superpowers:writing-plans <goal>`.
