# Comment Review Mistakes

Patterns where the automated reviewer has over-called, mis-calibrated, or otherwise got it wrong.
Updated automatically from author replies to review comments.

Each entry is a **pattern**, not a case study: no specific PR numbers, no specific file paths, no team-specific details. The goal is a durable principle future reviews will apply.

1. Don't flag missing tests as blocking when 1–2 focused behavior tests or smoke checks cover common user-visible flows. A change needs proof the behavior holds, not layer-by-layer coverage.
2. Don't require new tests for PRs that only change documentation, manifests, workflow YAML, or artifact pins. Note gaps as low/nit at most.
3. APPROVE when there are no findings medium or higher. Low and nit findings are noted in the review but do not prevent approval. Only `blocking` and `medium`-tagged findings warrant `VERDICT: COMMENT`.
4. When approving with nit/low findings, prefer `VERDICT: APPROVE — pending: <nit1>, <nit2>` so the approval body communicates what minor things would be nice to clean up. e.g. "Approving — pending: tighten empty-string guard in pushSlackAccount, add one argv-ordering test"
5. Don't demand duplicate in-repo producers when an existing out-of-band source already populates the data and integration checks cover consumption. Avoid forcing redundant architecture in feature PRs.
6. Do flag user-facing help text or docs that drift from app behavior. Consistent messaging is part of the user-visible contract.
7. Don't flatten API shapes when the existing structure makes domain roles clearer to consumers. Agent-readable interfaces can matter more than fewer fields.
8. Don't propose replacing `assert X` (or other fail-fast guards) with explicit raise + logging context. The user's `Fail-Fast` standard prefers the assertion crashing loudly on internal-caller bugs; logging+raise is bloat unless the code sits at a trust boundary.
9. Don't propose `isinstance` / type-validation checks for internal callers. Validation belongs at trust boundaries (user input, external APIs); internal calls trust their callers — adding type guards calcifies the call shape and contradicts `Concise Code`.
10. Don't propose state-reset / fallback writes ("set X = default in case prior init left it dirty") unless the polluting scenario is observed in production, not theoretical. A fallback chain for module-global pollution mostly fires in tests and locks the surrounding code into preserving both branches forever.
11. Don't propose wrapper dataclasses, snapshot views, or new DI seams when a 1–2 line direct fix solves the same problem. Snapshots and freeze-views are remedies for *repeated* problems, not first instances; "Three similar lines > premature abstraction" applies.
12. Don't propose streaming / incremental rewrites of small in-memory operations on theoretical perf or OOM grounds. Cite a measured failure or skip — the streaming version typically adds 15+ LOC of state machine, and the in-memory version costs nothing on the inputs that actually arrive.
13. Don't propose adding companion tests, CI guards, or regression coverage for scenarios that haven't been shown to actually occur ("no test for prod re-enable", "no test that this can't happen"). Tests calcify too — every test fixed in stone preserves the contract under test, even when the contract was wrong. Cite a measured failure, an in-flight class of bug, or skip.
14. Don't propose remedies that solve for users, scale, or behaviors the product doesn't have yet. Match remedies to the product's actual stage and scale; the elegant + fail-loud version of a fix is preferred over the defensive version that silently handles a hypothetical population.
15. Lead non-bug findings with the #1 assumption as a question, not as an assertion. For scope-creep findings specifically, the question must name the cost: *"adds complexity and makes PMF iteration harder."* Declarative voice is reserved for high-confidence bugs (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). When a finding is asserted but the assumption could go either way, that's a calibration miss — reframe it.
