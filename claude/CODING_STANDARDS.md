# Coding Standards

Canonical coding principles for my projects. Referenced from `CLAUDE.md` (all coding work) and `REVIEW_PRACTICES.md` (automated + human review). Hand-curated — auto-tuning from `learn-from-replies.sh` targets `COMMENT_REVIEW_MISTAKES.md` only, not this file.

## Don't Commit Plans

- **Implementation plans, design notes, scratch files, and other planning artifacts must NOT be committed to feature PRs.** They balloon the diff and obscure scope creep — a 12 LOC code change shouldn't ship alongside a 900 LOC plan riding in the same PR.
- If a plan needs to persist, keep it on disk under the gitignored path (or in a sibling repo/branch) — never inside the feature PR.
- Add the planning directory broadly to `.gitignore` (e.g. `docs/plans/`). Don't ignore plans by individual filename — the narrow form rots the moment the next plan lands, and reviewers won't notice the gap until a multi-hundred-LOC plan rides in a feature PR.
- The diff stat is reviewers' first signal of scope. Planning text inflates it past the point where reviewers can tell whether the actual code change is small or large. Keep that signal honest.

**Concrete origin:** `srosro/knightwatch-reviewer#53` initially shipped as +1002/-61 LOC. The actual prompt + test edits were ~12 LOC; the rest was two committed plan files (+936 LOC). The reviewer's LOC-as-scope-proxy heuristic was defeated until the `.gitignore` was reverted from a per-filename allowlist back to the broad `docs/plans/` rule.

**Review question:** *Is the diff stat an honest signal of this PR's scope, or are planning/scratch artifacts inflating it?*

## Anti-Bloat — Don't Propose These Remedies

LOC is a stand-in for **conditionals + special cases + defensive branches + new abstractions** — those are the actual cost being managed. Each calcified branch survives every future refactor and shapes the next change.

- **The test for any edge-case handler: *does the edge case actually happen, or will it in the near future?*** If neither, the remedy is bloat regardless of how the line count nets out.
- **Don't propose companion tests, CI guards, or regression coverage for unreachable scenarios** ("no test for prod re-enable", "no test that this can't happen"). Tests calcify too — a test for a scenario that doesn't occur preserves a contract that may have been wrong, and the next refactor has to keep that contract working forever.
- **When reviewing a PR or applying a bot's suggestion, don't propose (or accept) any of this section's flagged patterns.**
- **Don't propose special-case branches to tolerate empty/missing data when an established placeholder works.** If a placeholder already used elsewhere fits, reuse it instead of branching to handle the empty value (`Concise Code` + `DRY`) — but reuse an *identifier* (phone, email) only when that exact value is **already surfaced to the same audience**; never promote a sensitive identifier onto a new surface where only a non-sensitive placeholder was established. A handful of operator-reachable historical rows are then a manual fix, not a reason to write backfill code. Worked example: `plow-pbc/plow#714` — reused phone-as-`display_name` (the phone was already that contact's identifier on the same owner-facing surface) over a blank+NULLIF owner special case.
- **Don't propose wrapper dataclasses, snapshot views, or new DI seams** for one call site. These are remedies for repeated problems; "Three similar lines > premature abstraction" applies.
- **Invariant-comment vs invariant-test trade-off.** When a bot asks for a regression test to pin a small, locally-visible invariant (e.g., a `|| true` whose purpose isn't obvious), a short code comment naming the constraint can be the LOC-negative substitute — names the WHY so a refactor can't silently strip it. Worked example: `plow-pbc/plow#617` round 9 (`c25ea9f3`) — counter-proposed a block comment above two `awk … | grep … || true` pipelines instead of a +25 LOC subprocess test with a fake-`sleep`-on-PATH seam. The comment pins the `set -euo pipefail` constraint inline; the test would have reintroduced a PATH-injection seam in the same shape as the deleted URL-override seam.
- **Don't propose assert→raise+log replacements outside trust boundaries.** See § Fail-Fast on assert vs raise — the assert form is preferred for internal-caller bugs unless `python -O` is a deployment surface.
- **Don't propose isinstance / type-validation checks for internal callers.** Validation belongs at trust boundaries (user input, external APIs); internal calls trust their callers.
- **Deciding a specific guard is a two-gate test, not one.** (1) *Reachability gate* — if an invariant makes the case impossible (a field the server *always* emits, a catalog that always carries the entry), **remove** the guard. (2) *YAGNI gate* — reachability is NOT an automatic keep: at our scale (~5 users, pre-PMF), even a *reachable* case can have its guard **declined** (composes with `CLAUDE.md § Lean Less Conservative`). **Keep** a guard only when the case is reachable AND failing loudly there would misattribute bad data as a critical-path **outage** (e.g. a continuously-polled liveness endpoint). A reachable-but-rare case *off* the critical path → lean to declining. Worked example, both calls correct in one PR: made `StatusResponse.models` required (catalog always carries the entry → the optional guarded an impossible case) but **declined** stripping `/status`'s config-parse guards (a malformed on-disk config *can* occur and `/status` is the polled liveness endpoint — throwing there surfaces a config error as a connectivity outage).
- **When pushing back on a bot finding whose remedy hits one of this section's don't-propose patterns, cite the section by name** (`Anti-Bloat`) and apply the LOC-negative or branch-negative version of the fix.
- **Don't propose state-reset / fallback writes** for hypothetical pollution ("set X = default in case prior init left it dirty"). Unless the polluting scenario is observed in production, the fallback locks the surrounding code into preserving both branches forever.
- **Don't propose streaming / incremental rewrites** of small in-memory operations on theoretical perf or OOM grounds. Cite a measured failure or skip.

**Review question:** *Does the proposed remedy add a branch / handler / abstraction for a scenario that hasn't been shown to actually occur?*

## Broken-Glass Test

> "For the entire beta period, people practically had to walk over broken glass to start using shared channels: for me to even send you an invitation, I'd first have to find out your 'workspace URL' which very few people knew." — Stewart Butterfield on Slack's shared-channels beta

- **The reviewer's job is to catch real bugs and push for elegant code that lets the team validate the product.** It is *not* to push for handling user types, scale, or behaviors the product doesn't have yet. Architecture complexity for hypothetical scenarios is broken-glass cleanup — calcified branches that have to be preserved through every future refactor — disguised as diligence.
- **The reviewer's job is not to:**
  - add architecture complexity for users, user types, scale, or behaviors the product doesn't have today,
  - ask for defensive code that handles scenarios that haven't been observed in production,
  - promote abstractions for one or two call sites "in case we add a third."
- **The reviewer's job is to:**
  - catch real bugs (things that have gone wrong, or will go wrong soon, for a real user),
  - push for elegant code that lets the team validate the product faster.
- **Source of truth:** this standard owns universal Broken-Glass policy, voice posture, and the bloat-vs-bugfix contrast pairs in § Question template. Each repo's root `REVIEW.md` owns that repo's operating point (stage, scale, repo-specific cultural emphasis, repo-specific contrast pairs). When a per-repo file is silent on something, this standard is authoritative.

### Subtractive remedies are higher-leverage than additive ones

- **At any severity, a remedy that reduces LOC is higher-leverage than one that adds LOC.** The asymmetry is structural, not stylistic.
- **Additive remedies pay rent.** Every new branch / guard / helper / abstraction has to be maintained, understood, and reasoned about by every later change. A `+30 LOC` validation guard for a scenario that hasn't fired isn't free; it's a calcified branch the next refactor has to preserve.
- **Subtractive remedies don't have a "failure mode not observed" argument** — *contract-preserving* deletions (dead code, unused helpers, redundant guards, copies of canonical content) don't introduce new failure modes; they remove them. The pre-PMF lens drops additive remedies whose failure mode isn't observed; it doesn't have anything to drop on the subtractive side. Behavior-removing deletions are different — they change contracts / side-effects / error-behavior and live under § Regression Risk, not here.
- **When in doubt, surface and apply the LOC-negative remedy.** Counter-propose the LOC-negative version of an additive one. Decline only as last resort. *This is just `Anti-Bloat` and `Concise Code` propagated forward — every line earns its place, and a line you can delete didn't earn its place yet.*
- **This section owns the principle; `babysit-pr/SKILL.md` § Step 6.5 (3-round rule) owns when to escalate during ambient PR monitoring.** Complementary surfaces — the `#47→#50` worked example in § Worked-example reframings grounds the principle in real history.
- **Voice posture: questions over prescriptions.** Default voice on every non-bug finding is **inquisitive**. State the #1 assumption explicitly as a question. The reviewer is the team's "could-this-actually-happen" check, not its "you must address this" enforcer. Declarative voice is reserved for high-confidence bugs only. The bar: *can you cite the failing path, the user-observable outcome, and the line where the contract breaks?* Examples that meet the bar — reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause. Examples that don't meet the bar — "this could break if X," "this would scale poorly to N users," "this is missing a guard for Y."

### Question template

```
Will [user state X / data shape Y / scale Z]?
- If yes, [proposed action].
- If not, consider cutting [proposed action] — adds complexity and makes PMF iteration harder.
[Optional: recommendation given the operating point.]
```


The phrase **"adds complexity and makes PMF iteration harder"** is load-bearing for scope-creep findings. It names the *cost* of the additive remedy so the author chooses between two visible costs (broken-glass risk vs. complexity), not between "fix the issue" and "ignore the reviewer." Acceptable variants when the cost differs: "calcifies a branch the next refactor must preserve," "trades simple-and-fail-loud for layered defenses."

**Universal contrast pairs (architecture bloat vs bugfix).** The pairs below ground the principle in concrete examples:

| Architecture bloat — DON'T (when the product doesn't have these users yet) | Bugfix — DO |
|---|---|
| Idempotency token for a hypothetical client double-send. | Code path that can charge a user twice today. |
| Thread pool / queue for an inline call running <10×/min. | Race where a webhook gets dropped under observed concurrency. |
| Multi-tenant scaffolding when there's one tenant. | Cross-tenant data leak when there are two tenants. |
| Wrapper dataclass / snapshot view so internal callers can't mutate state. | Function whose contract changed but two callers still crash. |
| Retry-with-backoff on an internal RPC that's never failed. | Retry on a flaky external API where you've seen the failure. |
| Pluggable provider abstraction for the second LLM you might use. | Bug in the one LLM call you're shipping. |
| Hand-rolled type validation on internal callers. | Validation at a real trust boundary (user input, webhook). |
| Feature flag for behavior nobody asked for. | Feature flag that's load-bearing for an in-flight migration. |
| State-reset / fallback writes for unobserved pollution. | Initialization bug actually causing dirty state in a reproduced path. |
| Companion test for a scenario that can't currently happen. | Regression test for the bug you just fixed. |

- **Dividing line: fix what's actually broken or about to be; don't build defenses for users / scale / behaviors the product doesn't have yet — fail loudly instead.** Repos may add their own repo-specific contrast pairs in their root `REVIEW.md`.

### Worked-example reframings

**Taxonomy demand for first-instance directory** — declarative version: *"`team-skills/` is a new repo storage class with no taxonomy or guard contract; the taxonomy and guard should name it."* Reframed:

> Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder. The existing protected-path guard already fails loudly if anyone ships `team-skills/` content into the runtime.

**Unrelated guard-update ask** — declarative version: *"`scripts/check_protected_paths.py` still omits `plow-local-token`; add it to the existing `user-state` rule."* Reframed:

> Has any agent task touched `plow-local-token` in the last fortnight? If yes, sweep this in a separate cleanup PR. If not, the guard gap is theoretical; consider cutting it from this PR's scope — adds complexity and makes PMF iteration harder.

**Demand for layer-by-layer regression tests** — declarative version: *"This bug-fix pass still ships without focused regression tests; 1-2 tests pinning `import_csv()`, `import_legacy_log()`, and `next_batch()` would cover the important paths."* Reframed:

> Has the upstream CSV format changed twice in the last quarter? If yes, 1-2 in-memory SQLite tests pinning the import path are worth ~10 LOC each. If not, fail-loud-on-bad-shape is acceptable; consider cutting the layer-by-layer coverage demand — adds complexity and makes PMF iteration harder.

**Substrate replacement reframing — `srosro/knightwatch-reviewer#47` → `#50`** — declarative version of what should have surfaced earlier: *"The 4 bash files implementing the orchestration pipeline (orchestrate.sh + critic-splitter.sh + run-specialist.sh + prompt-build.sh, ~530 LOC combined) drive 5+ rounds of byte-level parser bugs each PR; the substrate is the source of the recurring class."* Reframed as a question with the deletion named:

> Will we keep paying parser-bug iteration cost on this 4-file bash splitter, or is the right move to collapse the substrate? A single `lib/pipeline.py` (~430 LOC, stdlib only, no external splitter parsing) does the same job and retires the byte-level parser bug class. **Net delta: -100 LOC + one fewer parsing seam.** If the answer is "we keep iterating on bash," consider cutting the next round of parser-validation findings — they add complexity and make PMF iteration harder for a substrate we're already planning to replace.

PR #47 grew to +2272 LOC across 23 rounds defending the 4-file bash substrate; PR #50 shipped the substrate replacement at net -20 LOC in 8 hours and merged. The reviewer pushing for "more validation, more fail-loud guards, more fence tests" round-after-round was *correct on each individual finding* — and *wrong on the structural ask*. The signal was visible from round 5 (cumulative additive remedies ≥ 100 LOC) but never surfaced because no specialist's mandate covers "this whole subsystem could be smaller in a different shape."

- **When cumulative additive LOC across rounds gets large and no leaf finding retires the class, ask what to delete, not what to add.** That is the lesson the `#47→#50` history in this section teaches.

**Review questions:**
- *Is this remedy solving for a user, user type, or behavior that the product doesn't have yet? At the current operating point (see per-repo file), would the failure even be visible in production today?*
- *Did this finding name its #1 assumption as a question, or was it asserted as if the assumption is settled?*
- *For scope-creep findings: did the question name the cost (adds complexity / calcifies a branch / makes PMF iteration harder)?*

For per-repo current operating points + concrete contrast pairs, see `REVIEW.md` in each tracked repo.

- **20-LOC remedy threshold.** When a proposed remedy adds more than ~20 LOC, the reviewer must explicitly answer three questions before raising the finding as `medium` or higher:

  1. **Will this affect our core product and help us find PMF?** Or is this covering an edge case?
  2. **If covering an edge case:** is there a simpler contract or infrastructure (a single-shape, fail-loud seam) that catches this AND other future edge cases for free? If yes, propose the contract instead of the local handler.
  3. **If neither (1) nor (2):** is the complexity worth it, given (a) the repo's `REVIEW.md` operating point (e.g. ~10 users won't experience the edge case at our current scale), and (b) the LOC cost slows down PMF iteration?

  Default when (1)+(2)+(3) all fail: **ship simple-and-fail-loud**, not elegant-defensive-coverage. We want simple, elegant code with some broken glass that fails loudly — the cost of a calcified branch outweighs the cost of a loud crash the operator can investigate.

  The threshold is a heuristic, not a cliff: a 15 LOC remedy that adds three nested conditionals is just as load-bearing as a 30 LOC remedy that adds one straight-line block. Use 20 LOC as the trigger for the three questions, then judge complexity by branches + special cases (per `Anti-Bloat`), not pure LOC.

- **Decline as last resort (look for the simpler shape first).** Before declining a finding under the 20-LOC threshold, ask one more question: **is there a deletion that retires the concern entirely?** If yes, that's the move — a refactor of *existing* code that absorbs the concern and removes complexity beats any additive remedy. Subtraction is the highest-leverage answer to a finding; the bot's job isn't just to push back on additive complexity, it's to surface the deletion that makes the concern moot.

  If no deletion retires the concern, then ask the next-best question: **is there a refactor that addresses the underlying concern AND simplifies existing code?** A finding's surface remedy may be additive (and rightly declinable as bloat), but the underlying concern often points at a real gap. Sometimes the gap is best closed by *changing existing infrastructure* — collapsing a duplicated handler, moving a check to a single seam, replacing a regex chain with a structured contract — rather than adding a new branch on top.

  When the bot raises a finding whose surface remedy would trip the threshold, the order of moves is:

  1. **Apply** if the underlying concern is real AND the remedy is LOC-negative or branch-negative as proposed.
  2. **Counter-propose with a simpler shape** — look for a refactor of existing code that absorbs the concern and removes complexity. This is the most useful reviewer move: it acknowledges the concern is real but answers it with subtraction, not addition. *Make this attempt visible in the reply* — even if the answer turns out to be "no simpler shape exists," the reasoning matters.
  3. **Counter-propose with a LOC-negative version** of the bot's remedy — same fix, fewer branches, no calcification.
  4. **Decline** (last resort) — only when none of the above fits AND the concern is theoretical at the operating point. Cite which threshold question fails (PMF impact / simpler-contract / operating-point worth). Bot persistence is not evidence: a re-raise or severity-escalation doesn't change the operating-point answer, so hold the decline (`plow-pbc/plow#663` — an SSRF guard on webhook-only URLs, caved-to under re-raise, only bought a dev regression and an ask for more conditions). Clean code that breaks loudly beats defense-in-depth.

- **Recurring same-class declines are a smell.** 3+ rounds of declining the same class as bloat means the bot is right that something is structurally off (unless the threat itself is theoretical at the operating point — then hold, per the **Decline as last resort** bullet's order-of-moves ladder), even if each surface remedy is itself additive. That's the signal to escalate to an architectural reframe (does the code extend the wrong seam? is there a better shape that retires the whole class?), not to keep declining.

  The Round-5 reframe on `srosro/knightwatch-reviewer#42` is the canonical example: 4 rounds of declining decline-history-classifier findings as REMEDY-BLOAT were correct *for the surface remedies* (each round, the bot proposed yet another regex priority chain). But the underlying concern was real — the regex chain was brittle. The right answer wasn't decline-and-ship; it was the structural reframe (drop the bash classifier, raw replies as context + explicit `<!-- decline:class=X -->` markers). Net -40 LOC, fewer branches, the recurring class disappeared. **The reviewer's job isn't just to push back on additive complexity; it's to surface the simpler shape that makes the concern moot.**

## Team Context

Small team (~3 engineers), ~10 active users, moving fast. Design bias:

- **Concise code that fails loudly > verbose, defensive code with brittle special cases.** We prefer short code that captures the *spirit* of the spec or desired UX and crashes when its assumptions break, over long code that bakes in handling for every edge case the author imagined. Each special case calcifies a decision and invites the next one. When the spec seems to require contortions, the right reflex is to question the spec (see § Reframe the Spec), not to add branches.
- **Elegance > defensive sprawl.** Code that reads cleanly and scales beats code that handles every hypothetical failure mode.
- **Loud breaks.** If an assumption is wrong, the code crashes — it does not silently degrade. No swallowed errors, no fallback chains, no softened tests.
- **DRY and missing-abstraction findings are first-class.** They are not style polish. A missing abstraction today is tomorrow's bug surface × N.
- **Iteration speed > compute time or $-cost.** What we're protecting isn't engineer-hours-spent (we'll happily spend hours on simplification) — it's *PMF iteration speed against calcified complexity*. A solution that costs more compute or more $/call is fine if it eliminates a class of code that would otherwise slow the next pivot. Lookup tables, hand-coded heuristics, and per-case branches are brittle in a way the compute bill never reflects. **Apply this at the option-listing surface:** when proposing remedies for a bug, list code-delta-zero options first (model/tier swap within an existing integration, config change, parameter tweak) — even at higher $-cost — before any option that adds new code paths, constants, or post-processing. "Code-delta-zero" means the integration stays the same; adopting a *new* vendor is an architectural commitment (integration work, data-shape drift, lock-in) and belongs with the new-code options, not the zero-delta bucket. The clever local fix that adds 30 lines is rarely the cheapest one for iteration speed.
- **Architecture decisions should not accrue tech debt.** A "fine-for-now" choice that the roadmap will force us to unwind in six weeks is a medium-severity finding, not a nit — flag it and propose the seam.
- **Reviewers — human and automated — weight findings with this section's design bias in mind, not just raw severity.**

## Concise Code (LOC is a cost)

- **Every line earns its place.** Verbose code is more bugs, more review time, more drift.
- **On a refactor, the win is shape — one path, one writer, one source of truth — with LOC as the signal, not the target.** A net-flat (or even slightly net-positive) PR that collapses N parallel state sources into one is a win; don't reject a shape-improving change for being LOC-neutral. Net-negative LOC stays the general preference — this is about not mistaking the corroborating signal for the goal. (Tell: a readiness consolidation that deleted three parallel "is-it-ready?" mechanisms was the win even though the per-unit tests it added kept the diff near net-flat.)
- Every conditional is a maintenance burden — all things equal, avoid it. Each `if`/`else` branch is a state the next reader has to hold and the next change has to update. When you find yourself adding a special case, ask whether a different seam would let you delete it instead.
- **The LOC/complexity delta — not the call-site count — decides every extraction. Compute the net delta first (new shared unit included).** Net-neutral-or-negative → DRY it, regardless of how few sites (two real duplicated sites, even one): the rule-of-2/3 thresholds do **not** gate a deletion. Net-positive → *then* the threshold applies: decline a helper/abstraction for one or two call sites when it adds significant LOC or a new concept (a hypothetical *third* caller is still not a reason to abstract). Restated: rule-of-N only blocks extractions that *grow* the code — an extraction that *shrinks* it is never blocked by "too few call sites." Don't cite "it's only rule-of-2" to decline a flat-or-negative dedup. "Three similar lines beat a *premature* abstraction," but "three" is a smell to look closer at, never a minimum count you must reach before DRYing — the moment a flat-or-negative dedup of real duplicates exists, collapse them. (Tell: I declined a shared source-preamble extraction across two scripts as "rule-of-2 bloat"; the steer was "rule-of-2 only matters when we increase LOC — if it decreases LOC, DRY it.")
- **When in doubt, don't write new code — reuse/extend the existing seam over a new module/component.** The implementation default is reuse over creation: extend an existing component/helper/module rather than add a new one. A new unit must *earn* itself by genuinely not fitting the existing seam, not by "cleaner separation" — and this overrides a spec's own decomposition when the spec proposed more new units than the change needs. (Tests are not "new code" in this sense — still write them.)
  - An "auto-X" variant of an existing operation (deploy, install, release) is a THIN wrapper over the existing runbook (a `just` recipe, a CI workflow, a `scripts/` script) — never a reimplementation of its mechanics. The operational tell that you took the wrong seam: a conceptually-small task ballooning in LOC + review rounds — stop and re-seam, don't keep patching findings (`plow-pbc/plow#858`, ~700 LOC/8 rounds, restarted as `#860`, ~50 LOC/2 rounds).
  - Count concepts at the LOGIC level: (# implementations of the same logic) + (drift-sync mechanisms like parity fixtures) + (new cross-language seams) — packaging weight (a heavier image, an extra runtime) counts less. One proven implementation reused verbatim across consumers beats a tidier second-language copy kept behavior-identical by fixtures; the drift surface is worst for security-sensitive logic (auth/owner gates).
- Don't add `if x:` guards when `x` should always be truthy
- **Comments must be DRY — a comment that repeats implementation details is a second copy of the implementation.** When the code changes, the prose doesn't, and now they conflict — the next reader trusts the wrong one. A comment earns its place only by stating a constraint the code *can't* show: an invariant, a hazard, an external contract ("the daemon caps `reason` at 300 chars", "`-i` keeps the key off argv where `ps` leaks it") — never what the next line does or a retelling of a mechanism implemented elsewhere. One canonical explanation per mechanism (the owning module's doc); every other site points to it in one line rather than retelling it — a mechanism essay duplicated across N files is N drift sites, same as any contract restated in N docs. (Tell: one provider-rename story retold in 5 files, a VM-teardown narrative in 4, across one PR series.)
  - **Hard ceiling: no in-body comment block over 3 lines — measure it, don't judge it.** A `#` / `//` run between statements that needs more than three isn't an in-body comment: it belongs in the docstring that owns it — the function's own, or the module's for a file-wide mechanism, or the file-header block where the language has no delimited docstring construct — or in the PR body, leaving a one-line pointer at the site. Relocation keeps a constraint *in tree*, so reach for the PR body only when the explanation is history rather than a live constraint; a refactor reads the file, never the merged PR. **Docstrings are exempt from this per-block cap**, module, class and function alike: they are the canonical site this bullet points *to*, and a docstring carrying a signature's contract is that contract's home rather than a second copy of it (test docstrings are the named exception, capped tighter at two lines by `TESTING.md` § Test Shape, since the test name already states the contract). **Splitting to fit is not compliance: relocate the block, don't fragment it. A file whose comment lines exceed its code lines fails the ceiling in aggregate — every comment line counts, docstrings included — the cap governs *placement*, the aggregate governs *volume*.** Deliberately a *number*, because "only the non-obvious" has no ceiling to check against — every block passes its own author's sincerity test, so volume only ever grows, and nothing on the reviewer side flags it. Tell: `plow-pbc/agent-mgr#34` shipped `lib/backup-homes` at **54 comment lines to 16 code lines**, its largest block 19 lines defending a design that isn't in the file — which the cap doesn't so much shrink as relocate, since that block belongs in the PR body entire.
  - **No review/PR archaeology in code.** `[knightwatch #5]`, "reviewer flagged", "the regression fixed in PR #N", "folded in from #N" talk to the reviewer, not the next reader — noise the moment the PR merges. An operator ruling that must survive from-scratch re-reviews lives at ONE canonical site (the owning module's docstring), phrased as the standing constraint ("loud failure over silent degrade"), never as a review-thread reference. **The ban is on the content, not the citation — no rejected-alternative defenses either.** "Staging through a temp file would have prevented X, but it cost four defect classes" is archaeology whether or not it names a PR, and it evades a citation-shaped ban by never printing a number. Why the code *isn't* something else belongs in the PR body or the commit message, which is where the next reader looks for history; the code carries only the constraint that is live. Tell: `plow-pbc/agent-mgr#34` argued its three findings at length in the PR body AND again in the file — the comment was a second copy of the PR body.
  - **Test comments** → `TESTING.md` § Test Shape is canonical (business value, one story per contract, never per-assertion narration).
  - **"Keep the two in step" is the tell that you wrote two copies.** A comment instructing a future human to sync it with another document has already conceded it is a duplicate — the rule above is one canonical site plus a one-line pointer, so write the pointer and delete the copy. Same for a comment that closes with "X owns the operator-facing version of this": if X owns it, say `see X` and stop. The sync note is not a mitigation, it is the drift site announcing itself. Tell: `plow-pbc/agent-mgr#34`'s `|| [ $? -eq 1 ]` block ran 9 lines and ended "`docs/HOWTO.md` … owns the operator-facing version of this; keep the two in step."
  - **No rot-prone anchors.** Hard line numbers ("`Foo.swift ~:1103`") and sibling-test-name cross-refs break silently on the next refactor — anchor to a symbol or section that a rename tooling-refactors with the code.
- Prefer direct access over fallback chains and nested conditionals

**Review question:** *Is this concise and elegant, or is there extra code that doesn't pay for itself? Does any comment restate the code, retell a mechanism owned elsewhere, or defend a design that isn't in the file? Is any in-body comment block over 3 lines (docstrings exempt from that cap, test docstrings capped at two)? Do the file's comment lines exceed its code lines?*

## Fail-Fast / Offensive Programming

- **No fallback *mechanisms* — the hot path works, or it fails loudly, as early as possible.** A backup data source, a runtime seed, a degraded mode "in case X is unavailable" is a silent-degrade state by construction — whoever proposed it (your own design, a reviewer probe, an SDK example). Instead: assert the precondition at the earliest boundary that can check it (import / boot / deploy — a failed deploy that leaves the old version serving beats a quietly-wrong runtime), or fail loudly at the point of use. Legitimate degradation exists only at boundaries we don't own (user input, third-party outages the product must survive), and even there it must be loud in a channel the owner reads. A tell you've built the wrong shape: the test has to patch a third-party library's internals to exercise the mechanism. Tell: plow-pbc/plow#977 — a 3-id model-allowlist add grew to +126 LOC absorbing a runtime sticker-price fallback seed plus guard-the-guard tests for when litellm's cost map lagged; the operator's ruling ("we generally do not write fallbacks — the hot path should work, and if it doesn't, it should fail loudly") replaced the whole mechanism with a 2-line boot assertion, −89 LOC.
- **Write fail-fast code.** If an assumption is wrong, the code crashes — it does not silently degrade.
- **Assert for internal-caller bugs, `raise` for guards that must survive optimization.** `assert X` is the right form for dev/test — it crashes loudly on broken invariants. BUT if the deployment can run with `python -O` (or any optimization mode that strips assertions), use explicit `raise <ExceptionType>(...)` so the guard survives. Worked example: `plow-pbc/plow#695` pass 1 — corgea flagged `assert row is not None` in `PeopleStore.upsert()` and `_load_person()`; replaced with `raise LookupError(...)`.
- Defensive code belongs only at system boundaries (user input, external APIs)
- **On a seam you own BOTH sides of, fail loud — don't paper it with conditionals that hide bugs and erode trust.** When you own both the producer and the consumer of an API/seam/data contract, a guard that tolerates a "shouldn't happen" state doesn't make the system safer — it makes it *less trustworthy*: a genuinely-broken producer stops surfacing, and every reader must wonder whether the odd value is benign or a bug. Reserve graceful degradation for inputs you don't own. Guard *placement* corollary: when a benign case genuinely must be tolerated, put the guard at the *specific caller* that legitimately produces it — never soften a shared/hermetic helper (that makes EVERY caller silently swallow the condition); keep the helper strict and pin its strictness with a regression test. Tell: a finalize-helper softened to return 0 on a missing file silenced ~78 legit-skip errors/day but also every real breakage; the operator's "we prefer to fail loudly so we can trust the underlying code" reverted the helper to strict and moved the `[ -f … ] || return 0` guard into the one caller with the benign case.
- **No suppressions without resolving the underlying issue.** Never `# type: ignore` / `# noqa` (or equivalents: `@ts-ignore`, `eslint-disable`, `# pylint: disable`). Use `assert x is not None` (narrows in basedpyright) or fix the actual type / lint violation. Suppressions turn a future regression into silence. Escape hatch: a single-line scoped suppression with an inline reason, reserved for cases where the type system genuinely can't express the truth (third-party stubs, generics interop edges).
- **Instrument before you patch when the cause is unresolved.** If `superpowers:systematic-debugging` can't pin the root cause from the available evidence (no audit log, no journal entry, no internal timeout matched), the fix must include the instrumentation that makes the next occurrence debuggable from the journal alone — otherwise you're shipping a symptomatic fix that doubles as opacity for the next incident. Example: plow-pbc/plow#680 → PR #93 added `_trace_sigterm_source` (logs `ppid`, parent cmdline, `/proc/self/status` `TracerPid` before re-raising SIGTERM) alongside the cascade-prevention fix, because the SIGTERM origin that triggered the original incident wasn't traceable from logs. When the path you're instrumenting *could* surface argv/env values to journald or chat, mask anything token-shaped per § Secrets before logging.
- No fallback chains: `a or b or c or default` — pick one source of truth
- Access data directly: `x["key"]`, not `(x or {}).get("key", default)`
- No swallowed errors: `try: ... except: pass`
- When encountering existing defensive code, rip it out and run tests. If they pass, the defense was bloat.
- Avoid `try/except` / `try/catch` in core logic

**Review question:** *Is this code non-defensive? Does it crash loudly when its invariants are violated?*

## DRY: Find Existing Logic Before Adding New

- **New functions, user-facing strings, and status reports must be grep'd for near-duplicates before approval.** Parallel implementations are the single most common LLM defect.
- Grep the repo for similar function names and near-duplicate strings.
- Intra-PR duplication (N near-identical blocks in the same diff) is a missing abstraction: *medium: dry*.
- **Calling a change "DRY" / "cleanup" / "simpler" → lead with the net add-vs-delete LOC ledger, not a list of deletable sites.** Before describing a new component or migration as "DRYing" something — or a rewrite as "simpler" — compute and state the **net** ledger (prod LOC added vs deleted, as a fraction of the surface being changed). "DRY"/"simpler" implies net reduction; using the framing for a net-*additive* change hides the real tradeoff and erodes trust the moment the operator runs the numbers. If it's net-additive, say so plainly and justify it on its **other** merits (a new capability, a control plane, a security property) — or recommend against shipping. Also name the load-bearing constraint that *forces* the duplication, since relaxing it is often the real lever. "It doesn't actually DRY" is evidence *against* shipping, not a reason to keep selling the framing. The duty fires on already-open/approved PRs too (`gh pr edit` the description when the diff sign contradicts it, distinguishing real DRY/deletions, testability/abstraction investments, bug fixes, and copy changes — the merged log is what the next reader greps) and upstream at the proposal stage (when proposing an edit to a dense doc/corpus, do the fold-in-and-cut pass and lead with the net-neutral version, not additive-only prose with the subtraction left for "later"). For a "simpler" rewrite specifically, check the diff **sign** against the intent: a "simpler approach" trending net-positive is the design layering on complexity instead of removing it — a wrong-shape signal to rethink before more code. (Tell: pitched a +4,416 prod migration as "rip out the duplication"; the honest math was net +3,600 — the duplication was forced by needing to run headless; leading with the ledger would have surfaced the real fork rounds earlier.)
- Duplicate logic with an existing repo site: *blocking: dry* — cite the existing site by path.

**Review question:** *Is this DRY with the rest of the codebase? Are we re-using existing functions where we should? Does the "DRY"/"simpler" framing match the net LOC sign?*

## Incremental Improvement

- **Leave each file a little better than you found it.** "Better" = fewer LOC, fewer conditionals, fewer special cases, clearer assumptions at the seams it consumes and exposes, and louder failure when those assumptions break. A bit slower at runtime is fine. If you're already editing something and spot an obvious tidy — two nearly-identical mocks that could collapse into a factory, an unused import, a one-line comment that restates the function name — take it.
- **Split the work: get the business-logic change working and tests passing first, then do the cleanup as a separate commit.** A reviewer should see the behavioral change cleanly on its own and the cleanup as its own diff.
- Don't sneak cleanup into the feature commit — it hides the real change.
- Don't block on unrelated cleanup — keep the focused change landable.
- If the cleanup is big enough that it deserves its own PR, make it its own PR — but "its own PR" is about *sequencing* a large/risky change for clean review, never a reason to skip or indefinitely defer it. A net-neutral-or-negative cleanup coupled to the current change (incl. a reviewer-flagged structural move that converges the review) gets folded in, not punted to a follow-up.

**Review question:** *Did the author leave the file measurably better than they found it, without muddying the business-logic diff?*

## Bug-Class-Recurrence

- **When the same class of bug has been flagged 2+ times on the same PR** — across reviews, or across multiple findings within a single review — **the right finding is structural, not local.** Patching individual instances has reached diminishing returns; the right move is to name the architectural shape that would make the entire class impossible (per-session value types, sealed enums for state, single-owner data, registries, dispatch maps) and recommend that.
- **A `Bug-Class-Recurrence` finding replaces — does not append to — the individual local findings of the same class.** Listing both anchors the author on the local fix; they will fix the local one and the structural finding becomes background noise.
- **If you genuinely cannot name the structural alternative, downgrade to `medium` and surface as an Open Question instead.** Do NOT fall back to listing local fixes.

**Worked example — `plow-pbc/plow#617` (delete the seam to retire the class):** rounds 3-5 surfaced the same URL/auth-boundary class against a `PLOW_INBOUND_URL` test override: shell-glob allow-list → userinfo bypass (`http://127.0.0.1:1@evil/...`) → `urllib.parse` validation in Python → cross-origin redirect with the bearer header. Each round's surface remedy was correct (and additive). The structural answer was to **delete the seam itself**: hardcode the production URL, drop the override-rationale, drop the 4 release-script tests that depended on it. Net delta: **-105 LOC** (`bf8f8d8d`). The recurring class disappeared in subsequent rounds because the surface it fired against was gone. Smaller scale than the `#47→#50` example below in § Broken-Glass Test, but cleaner illustration: the deleted code was *single-purpose* (testing), so there was no contract loss to absorb.

**Worked example — `plow-pbc/plow#664` (share the impl to retire the class):** across ~5 rounds the release preflight kept re-deriving checks (Sparkle pubkey, codesign identity, `generate_keys` path, empty-AWS-profile) that drifted from what `plowd-beta-package-signed` actually used — each drift a fresh blocking finding. The structural fix was **single-owner**: hoist each check into a shared `_lib.sh` helper both the preflight and the packager call, so they can't diverge by construction. A third flavor beside delete-the-seam (`#617`) and replace-the-substrate (`#47→#50`): when two implementations of one contract drift, the fix is to *share the implementation*, not patch each instance.

- **Author-side: when you adopt the structural fix, sweep every existing surface in the same push — at the FIRST fix, not once-per-reviewer-round.** The moment a fix addresses a *class* ("this config write must be atomic", "this path must do X"), grep for every sibling site of the class and fix them all in the same pass. A whole-PR re-review evaluates from scratch and flags any unswept sibling as a fresh finding, so dripping the fix one surface per round just burns review cycles. `plow-pbc/plow#663`: the filename→hint injection class and the "read delivered files" guidance each had several surfaces fixed one-per-round; a single sweep would have saved ~3 rounds. When the restated contract is *prose*, the sweep covers the WHOLE tree — posture files (each repo's root `REVIEW.md`) and their `ref/` mirrors, every README, and every phrasing variant (the count form plus each inline enumeration) — then re-grep to confirm zero before pushing (an install-report contract realignment took ~4 rounds because each pass under-scoped the grep).
- **Author-side: a decision that keeps leaking → collapse to ONE state-invariant, not per-site flags.** When the decision logic itself keeps leaking (per-site changed-flags, exception-type discrimination, accumulating special cases), stop patching leaves and replace it with one end-to-end check that can't be locally bypassed — a before/after state compare, or an *existing* readiness/identity flag every path already sets — rather than threading a "did I change it?" bit out of every writer. Shapes: always-do-it (simplest, when the op has no abort/early-exit) vs before/after compare (when it does); once always-do-it accrues ≥2 structural special-cases, switch to the compare — it subsumes them. Review-loop tell: a finding-class recurring across ~3 rounds on DIFFERENT surfaces means the *contract* is under-specified — name the gap and fix uniformly in one pass, proactively, not after the human asks "is the whole approach broken?" (`plow-pbc/plow#823`: the ambient-write class recurred ~4 rounds across subsystems while only the named surface got hardened each round; `#948`: two AskUserQuestions + ~4 per-site rounds dissolved into one `gateway_config_written` invariant + one grep sweep).
- **Author-side: don't open a surface you won't fully sweep.** When a probe targets a shared contract in an *adjacent subsystem* outside the PR's purpose, either fully own the root fix (sweeping all its surfaces, per this section's sweep-every-surface-in-the-same-push bullet) or decline it as not within the PR's intent and defer to a focused PR — never a partial touch of just the one file the probe named. A partial cleanup is the worst of both: it pulls that subsystem into the PR's review surface (so re-reviews keep finding its *other* inconsistencies) without fixing the root, spawning per-round whack-a-mole. Tell: `plow-pbc/plow#715` — a round-4 probe at `app/plowd/.env.example` got a partial cleanup; the plowd env-contract then drew fresh probes 3 rounds running until the edit was reverted to re-scope, and the real fix landed as a focused follow-up (`#725`).
- Same class flagged in 2+ prior reviews → *blocking: bug-class-recurrence*.
- 2+ findings of the same class in the current review draft → *blocking: bug-class-recurrence* (collapse them into one structural finding).
- Supersedes `Narrow-Fix` after the first occurrence of the class.

**Review question:** *Is this the Nth instance of a recurring shape? If so, what's the structural alternative — the one piece of code that would make every instance disappear?*

## Ownership Census — count the owners before touching a concern

- **Before building — or absorbing review fixes into — any change that touches state, lifecycle, or infrastructure behavior:** name each lifecycle event the change touches (`concern/event` — creates X, destroys X, recreates X, stops X, delivers X), which code path owns it today, and which owns it after. Rows are keyed by *event*, not bare concern: a concern legitimately has different owners for different events (X's creator ≠ X's stopper is normal). **Two owners of the same lifecycle event is itself the finding** — ask "should one owner absorb this?" *before* adding any machinery (guards, fail-louds, tests, semantics comments) to either path. Machinery hardened onto a path that shouldn't exist is the most expensive waste: it reviews well, tests green, and calcifies the duplicate.
- **The comment tell.** If you're writing a comment explaining why a mechanism behaves strangely (a path accessor that mkdirs, a read-only probe that mutates, a "one-time" job that runs per-boot), that comment is a census entry: the mechanism's ownership is wrong. Fix the owner; don't ship the explanation next to a compensating flag.
- **Census before triage.** In a review loop, group the round's findings by the lifecycle event+owner they touch before per-finding apply/decline. Findings clustering on one event are symptoms; the ownership question is the fix. This is the generative, before-the-fact counterpart of § Bug-Class-Recurrence (which fires only after the class has burned 2+ rounds).
- **A new owner for a one-time event is a red flag at alpha scale.** A shipped migration, a rollout fence — prefer the operational runbook step and zero code; permanent product code should not own a one-time event. (Compatibility shims are governed by § Backwards-compatibility.)

**Worked example — `plow-pbc/plow#1032→#1036→#1041` (the dual-owner trap):** the census row was `VM/recreate → build recipe + app startup → app startup` — recreation had two owners (`just vm-recreate` AND the bundle-digest mismatch in `LimaVMManager.start()`). Across ~12 review rounds and three PRs, the loop hardened the build-side path one finding at a time (fail-loud probes, a teardown disposition matrix, a 13-line branch-semantics comment) — and no author or reviewer ever asked why recreation had two owners, because the duplication predated every diff under review and per-finding triage never reads outside the diff. The consolidation commit (`e1bb407a`, "give app startup sole VM recreation ownership") deleted the machinery wholesale, −50 LOC, in one designed pass. Findable at any point by counting owners.

**Review question:** *How many code paths own each lifecycle event this change touches — and does the change add, duplicate, or consolidate an owner?*

## Regression Risk

- **New code must not quietly change existing business logic.** Any change to a function's contract, return shape, side effects, or error behavior needs an explicit callout.
- Changed semantics of an existing function without updating call sites: *blocking: regression*.
- A bug fix without a regression test that exercises the old-bug path is *blocking: tests*.
- New conditional branch that alters legacy-path behavior: *medium: regression* unless proven safe.

**Review question:** *Does this introduce regressions? How does it change existing business logic, and is that change intentional and covered?*

## Reframe the Spec

- **Any single new block over ~20 LOC is a smell.** Pause and ask whether a spec or UX tweak would delete most of that code. Don't silently accept contorted code to match a literal ask — name the simpler alternative so the author can choose.
- If satisfying a spec detail is adding notable complexity: *low: spec-reframe* with the alternative described in one sentence.
- If the complexity is structural (not just a spec ask): escalate to *medium*.

**Review question:** *Would a small change to the spec or UX accomplish the spirit of the request while significantly reducing complexity?*

## Name the Shape

- **Before writing code, name the *class* of problem:** parsing, validation, dispatch, retry, auth, serialization, formatting, batching, state, idempotency, audit logging, feature-flag gating. Each is a recurring shape with a preferred home in the codebase. Pick the shape first; the lines come second.
- **Two failure modes:**
  - **Five shapes for five similar problems.** Each new feature lands with its own auth check, its own retry loop, its own date format, its own error shape. Each PR looks fine in review; the policy now lives in 17 places. If you are the second instance of a missing shape, *that* is the moment to introduce one — not the fifth.
  - **Wrong shape.** Regex when the upstream could emit structured data. Hand-rolled validation when pydantic/zod is already in use. `if kind == "A": ... elif kind == "B": ...` instead of a dispatch dict. Bool-soup state instead of an enum. The code works on today's input and silently breaks on the next variant. Regex is the canonical example — treat regex on string-typed input as a smell that *structure got discarded upstream*. The fix is usually to make upstream emit data, not to grow the regex.

- **Before writing: grep for how the codebase already handles this class.** If a shape exists, conform. If none exists and you are not the first instance, you have just discovered tech debt — flag it.

**Review question:** *Did the author name the problem class and conform to (or establish) the codebase's shape for it, or did they solve only the literal symptom?*

## Generalize the Fix (Narrow-Fix)

- **A fix tied to one reported input (regex, string equality, hard-coded special case) is a narrow fix.** Ask: what is the next variant of this input, and does this code cover it?
- If the root cause is systemic (parsing, state machine, schema), fix the class, not the instance.
- Narrow fixes that won't survive the obvious next bug are *medium: narrow-fix*.
- `Narrow-Fix` is only valid on the FIRST occurrence of a class on a given PR. A second instance of the same class on the same PR escalates to `Bug-Class-Recurrence` (§ Bug-Class-Recurrence) — repeating `Narrow-Fix` review after review erodes the tag's signal and traps the author in a local-fix loop.

**Review question:** *Is this a root-cause fix or a patch for one symptom?*

## Tests

For the canonical testing bullets (test behavior not implementation, never skip, fail loudly, run `just test` after every change, fixtures/factories), see `CLAUDE.md` § Tests and `TESTING.md`. Review-specific additions:

- **`just test` must pass before merging.** The pre-merge gate is non-negotiable: no merge on a red bar, even if the change is "obviously" safe. If a repo doesn't have a `just test`, add one before landing the first PR that needs gating.
- A change crossing multiple layers (e.g. Swift → plowd → API) needs 1–2 focused behavior tests, not exhaustive layer-by-layer coverage
- **New tests in the plow repo should align with `docs/TEST_PATTERNS.md` and `./tests/README.md`** — the repo's own test-writing conventions. Tests that diverge from those patterns without a good reason are a *low: tests* finding.

**Review question:** *Are the tests loud-on-failure, aligned with the repo's test patterns, and focused on behavior rather than implementation details?*

## Migrations

- **Never hand-write Alembic migrations.** Always use `alembic revision --autogenerate` to generate them from model changes.

**Review question:** *Was this migration autogenerated?*

## Backwards-compatibility

- **Default: don't carry backcompat.** A rename or protocol change is a clean rewrite — drop the old shape, ship the new one, retire the legacy code path. No `if old: else new:` branching that calcifies the old shape into perpetuity. This applies to server-internal renames, intra-API protocol changes, and anything across a boundary the same deploy crosses (one git repo, one CI run, one rollout).
  - **Exception: cloud API ↔ user-installed client skew.** When a system has a *centrally-deployable server* and *user-installed clients* that can't be rolled out simultaneously, the API must remain tolerant of both the old and new client shapes during the rollout window. **The shim goes on the API, never the client** — a client-side bridge would land only after the client upgrade we're already waiting on, which defeats the point. The asymmetry is monotonic: server deploys in minutes to everyone; client upgrades trickle over days-to-weeks (Sparkle update / morning install / App Store review) and never reach some users. **Tell:** a fix that "teaches the on-device daemon / runtime / app to accept both old and new" is a client patch — wrong surface, even when correct in isolation.
    - Before reaching for a client-side bridge for an API skew, ask: *"can the API be made tolerant of both shapes instead?"* — if yes, that's the right surface even when the client patch is shorter or more obvious.
    - Cases for a client patch: (a) the API genuinely cannot bridge (a value not derivable from request data), or (b) explicit human direction to ship the client fix.
    - The boundary that triggers this exception is *user-installed-client-vs-centrally-deployed-server*. It does not generalize to two services inside the API talking to each other, or to inter-process boundaries inside a single client install — those are clean-rewrite territory by this section's **Default: don't carry backcompat** rule.

**Concrete origin:** `plow-pbc/plow#739` taught plowd (on-device daemon) to accept the legacy `client_kind="openclaw"` to unwedge installs against a pre-#692 prod cloud. That client patch would have helped users only *after* they installed the next Plow.app build — defeating the point. The right surface was the API: deploying current main (which already had the forward rollout bridge for `agent-runtime → openclaw` peer.status mirror) instantly unwedged every install on the planet. PR #739 was closed; the API deploy of #743 was the action.

**Review question:** *If this PR ships a backcompat shim, is it on the API side of a user-installed-client boundary? Anywhere else, default to clean rewrite.*

---

## How reviewers should weight these

- **Reviewers rank findings by severity first (`blocking` → `medium` → `low` → `nit`), then within a severity band by the ordered list in this section.**

  1. **Tech-debt and architectural findings** (missing abstraction, DRY violation, design that won't survive the roadmap) — these compound.
  2. **Broad-correctness findings** that affect many paths or users.
  3. **Surface-area findings** touching many files.
  4. **Localized fixes and style** rank LAST within their band.

- **If two findings compete and one is "code that won't scale as the team grows" vs. one that is "line-level style," the scalability finding wins the higher slot even at the same severity.**
