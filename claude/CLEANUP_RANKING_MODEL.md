# Cleanup format + nudge model

Reference doc for `skills/cleanup/SKILL.md`. Defines the canonical ranked formats for corpus files,
skills, and autonomy proposals. `SKILL.md` is the workflow; this file is the data model it operates
on. Rank is positional throughout—no counters except proposal `+1` session slugs.

## Canonical format (every ranked corpus file)

`CLAUDE.md`, `CODING_STANDARDS.md`, `REVIEW_PRACTICES.md`, `TESTING.md`, `PR_LIFECYCLE.md`,
`AUTHORING.md`, … all follow one shape so nudges can target bullets/sections deterministically:

- `# Title` (one or more) + optional intro prose. A file may use additional `# H1` dividers (e.g. `CLAUDE.md`'s `# Global Rules`) to group sections; treat each `# H1` block as a separate ordering scope.
- `## Section` headers — the **section-level** nudgeable unit.
- Inside a section: `- bullet` blocks — the **bullet-level** nudgeable unit. A "bullet" is one
  top-level `- ` line **plus** its indented children / continuation lines; it nudges as a whole block.
- `### Subsection` headers allowed; their bullets are nudgeable within the subsection.
- **Numbered `1.` lists** — only for genuine ordered sequences (e.g. `CLAUDE.md` § Branch Workflow's
  branch → PR → babysit → merge). They carry *sequence* meaning, not *rank* meaning, so they are
  **never nudged** (reordering them would make the steps chronologically wrong).
- **Section headers (`##`/`###`) are never numbered.** A sequence is a numbered *list inside* a
  section (above), never the section header itself — so every section is a uniform, nudgeable
  directive-section. The first heading in every file is an H1 `# Title`. Both invariants are enforced
  by `tests/test-corpus-format.sh` (run under `just test`); the file-exclusion set there mirrors
  `skills/cleanup/SKILL.md § Step 2`.
- **Prose paragraphs** allowed for orientation/context — a section lede, a table lede, commentary on a
  template — and never nudged. But a paragraph that states a **directive** belongs in a `- ` bullet:
  prose is unreachable by the nudge op, so a rule written as prose can never climb however often it is
  cited. One directive still gets its own bullet even when it is the section's only one — it is the
  seed the next directive ranks against. The judgment is directive-vs-scaffolding, which is why this is
  a rule for authors rather than a lint; markdown shape can't tell the two apart.
- **A bullet's content must be position-independent**, because a nudge can move it. No "the paragraphs
  above" / "see the back-reference below" / "as noted above", and no definite reference to a term a
  *neighbouring bullet* introduces ("if **the thrust** isn't there" when the previous bullet defines
  it). Anchor to content instead — "before the intent / business-case paragraphs", "the `babysit-pr`
  Step 7 pointer in this subsection". Prose gets this for free (it can't move); a bullet doesn't.
- **Converting prose to bullets is not a purely mechanical reshape** — de-positionalize *first*. Prose
  can safely say "above" because it is frozen; the moment it becomes a `- ` block, Track A can reorder
  it and that wording is wrong. Word-preserving is not meaning-preserving here, so a "zero words
  changed" diff is necessary but not sufficient. Same trap when *splitting* one paragraph into two
  bullets: a rule and its rationale (or its remediation) that can be swapped will eventually read in
  the wrong order — if they only make sense together, they are one bullet.
- **Converting a *lede* un-freezes it, so sweep what depended on its position too.** The paragraph
  itself is only half the reshape: whatever followed it was written against a fixed anchor, and now
  that anchor can move. Three forms, all fixed the same way — make it a child of the new bullet, or
  make it self-contained: a **dependent bullet** ("Specifically: …", the steps of a procedure the lede
  names), an **anaphor** ("This rule overrides …", "the exceptions this section's lede names"), and a
  **frozen block the lede owns** (a numbered sequence, a recipe, a table — never nudged itself, so a
  peer bullet swapping past the lede orphans it).
- **No hidden metadata / counters** anywhere — rank is *position*, nothing is stored.

## The nudge op (Track A)

A nudge is a single deterministic positional move:

- **Bullet up one.** A cited bullet swaps with the bullet immediately above it in its section.
- **Parent section up one.** The bullet's `## Section` swaps with the section immediately above it — **but never across an `# H1` divider**: a `## Section` reorders only within its own `# H1` block, so a Global Rule can't climb into the file's preamble.
- **Cap ~3 nudges per file per run** — low churn; the corpus self-sorts gradually over many sessions.
- **Block-aware.** Moving a bullet moves its whole block (the `- ` line + indented children). If two
  blocks in a section share indistinguishable leading text, nudge the cited one by content, not by a
  blind line move.
- **Cited this run, or not at all.** A citation is nudgeable only in the run that observed it. When a nudge commit never reaches `main` — stranded on an unpushed slot, dropped by a conflict, abandoned with a branch — do not re-derive it (the script drops only on a reorder conflict, so one can still be sitting in a slot — srosro/code-config#174): replaying it injects ranking signal from a session many runs stale, against positions that have since moved for reasons that run never saw. Recover such a commit's *content* (a `PROPOSALS.md` entry is durable); discard its *ordering* (a relative swap is not).
- **Already at top** → no move (can't climb further).

**Selection vs operation.** The *operation* is fixed (move-up-one); only the *selection* — which
bullets — is LM judgment, bounded to "bullets cited this session." A bullet is **cited** when it
demonstrably helped you work autonomously this run — most strongly when **you would otherwise have
gone back to the human but the answer was already in that rule**. Numbered-sequence and prose
"citations" are noted only informationally; they are never nudged.

**Nudge the bullet that STATES the rule you used — follow the text, not the file you read it in.**
One destination per citation, aimed wherever the rule's own wording lives. When what helped you was
a pointer — a `## Top Rules` entry, a stub section deferring to another file — the rule it names is
the thing you used, so the nudge lands on that rule's bullet in the file that holds it. `CLAUDE.md`
is the only corpus file loaded by default, so a citation that stops at the pointer spends every
session's ranking signal on `CLAUDE.md` and leaves the owning file permanently unsorted. A bullet
that states its own rule is nudged in place, whatever it cites in passing. **The destination must be
a `- ` bullet in a ranked corpus file** (`SKILL.md` Step 2's set) — resolve to a skill body, a
non-ranked file, or prose/numbered text with no bullet of its own (`## Top Rules` → § Branch
Workflow; `PR_LIFECYCLE.md` § When the loop stalls → `babysit-pr`), and the citation is informational
only: it nudges nothing, and never falls back to the pointer.

**Why position, not counts.** Positional rank produces a minimal diff (a single adjacent swap) and
needs no stored state. Over many sessions, repeatedly-cited rules bubble to the top — a gradual,
self-correcting sort with no counter to maintain or drift.

## Canonical skill format + garden op

Every `claude/skills/*/SKILL.md` has frontmatter, one H1, a short lede, then its first H2:

```markdown
## Priority

- `§ Guardrails` *(pinned)*
- `§ Most-used workflow section`
- `§ Next-most-used section`
```

- `## Priority` contains **3–7 pointer-only bullets**. Each pointer names an exact H2 elsewhere in
  the same skill; it carries no copied rule text, so the index cannot drift from the canonical body.
- A safety/authority section may be the first pointer and marked `*(pinned)*`. It never moves or gets
  evicted. No other pointer is pinned.
- A cited or autonomy-implicated section moves up one slot, capped at ~3 moves per skill per run. A
  cited section missing from the index enters at the bottom; if the index is full, evict its last
  unpinned pointer. Rank is the pointer's position, not the body's physical location.
- Section bodies stay in workflow order. Ordered steps, tables, examples, and reference material do
  not move merely because their priority pointer moved.
- Track A may make one **semantics-neutral, LOC-negative** garden edit per implicated skill: delete
  exact duplicate navigation/scaffolding, or replace a repeated directive/example with a pointer to
  the canonical owner only when no unique condition, authority, safety boundary, or edge case is
  lost. Uncertainty means no edit; stage a Track B proposal instead.
- `tests/test-corpus-format.sh` enforces the structural portion: `Priority` is the first H2, pointer
  count is bounded, targets exist exactly once, and only the first pointer may be pinned.

## PROPOSALS.md (Track B staging)

Content learnings live in `claude/PROPOSALS.md`, the same positional model applied to a
staging doc the human harvests from. Every new proposal and `+1` uses this format; legacy blocks are
grandfathered until touched:

```markdown
## [removes-handback] <proposal title>   ← tag only when the rule removes a concrete operator hand-back; omit otherwise
**Change:** <the unblock move generalized into a rule you could apply yourself>
**Why (autonomy):** Stop — <avoidable hand-back>. Prior authority — <evidence/authorization already
available>. Unblock — <what the human had to repeat or do>.
**Next instance:** <a concrete different repo/tool scenario where the rule would fire>

  ### +1 — <YYYY-MM-DD> · <session-slug>
  **Change:** <the related tweak this session would make to the proposal>
  **Why (autonomy):** Stop — … Prior authority — … Unblock — …
  **Next instance:** <different future scenario>
```

- A `## <proposal>` is a nudgeable unit within `PROPOSALS.md`; its **rank = the number of distinct
  `<session-slug>`s among its nested `### +1` comments** (not raw `+1` count — so a same-session
  double-append can't inflate support). **Pre-append dedup:** before adding a `+1`, if the proposal
  already carries a `+1` from this session's slug, merge into that block rather than appending a
  second. After adding a `+1`, if the proposal now outranks the proposal above it, nudge it up one
  (same move-up-one op) — the most-supported float to the top. **Ties (equal rank) keep insertion
  order** — never reshuffle equal-rank proposals (avoids churn; the bulk start at 0 votes).
- A `+1` comment is a **nested mini-proposal** (same three fields), indented under the proposal it
  supports. New, unrelated learning → a new `## <proposal>`; related → a `+1` (not a competing dup).
- **Next-instance test (staging gate):** a proposal or `+1` enters this file only if the session can name, in
  one sentence, a concrete *different* future scenario (different repo, different tool) where the rule
  would fire. Repo-specific tips that fail the test belong in that repo's own `CLAUDE.md`/skills or in
  project memory — not here. The gate encodes the harvest bar: a reusable rule survives the death of
  the artifact that taught it. (Operational wording lives in cleanup `SKILL.md` Step 3.5.)
- A `[removes-handback]` **title tag** marks a proposal whose rule would have removed a concrete
  operator hand-back (an AskUserQuestion, a handed-back checklist, a gate the agent couldn't clear).
  It's the visible form of cleanup's hard-stop grade — **not a rank input** (rank stays the distinct-slug
  count); it's a harvest-priority signal the human filters on (`grep removes-handback`). Quality-steer
  proposals and the pre-tag legacy backlog stay untagged, so the genuine babysitting-removers pop.
- One `+1` per proposal per session. Proposals never auto-apply — the human harvests the top into the
  corpus, then deletes them from `PROPOSALS.md`.
