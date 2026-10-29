# Testing Practices

Use this as the default testing policy unless a repository has stricter local
instructions.

## Fixtures And Factories

- Prefer shared fixtures and factory helpers over large inline setup blocks.
- Prefer one factory with defaults and overrides over multiple fixture variants
  for the same data shape.
- Use factory fixtures for repeated payloads, DB rows, model objects, API
  clients, and server lifecycle setup.
- In each test, customize only what matters for that behavior. The test body
  should make the business case obvious.
- Raise common factories when they are reused across suites. Keep suite-specific
  setup in the suite's `conftest.py`; keep single-test setup local to that test.
- Do not duplicate equivalent factories across test suites. One reusable source
  of truth is easier to update when schemas or models change.
- For typed Python factories, use a small `Protocol` when the callable shape
  matters instead of widening to `Any`.
- For workflow or e2e tests that may run in parallel, generate unique test data
  through the factory, such as UUID-suffixed names or emails. Do not hardcode
  shared identifiers.

Example:

```python
@pytest.fixture
def payload_factory() -> Callable[..., dict[str, object]]:
    def create_payload(**overrides: object) -> dict[str, object]:
        defaults: dict[str, object] = {
            "user_name": "Alice",
            "consent": True,
            "relationship_type": "romantic",
            "communication_goals": "better listening",
        }
        return {**defaults, **overrides}

    return create_payload


def test_partial_payload(payload_factory):
    payload = payload_factory(communication_goals=None)

    assert payload["communication_goals"] is None
```

Avoid this:

```python
@pytest.fixture
def full_payload_data():
    ...


@pytest.fixture
def partial_payload_data():
    ...


@pytest.fixture
def minimal_payload_data():
    ...
```

## Core Philosophy

- Never hide failures. Do not skip, xfail, comment out, or weaken a failing
  test to make a suite pass.
- Follow red -> green -> refactor TDD: write the failing test first, implement
  the smallest change that passes, then clean up while tests stay green.
- If config, credentials, services, dependencies, or databases are missing,
  set up the environment or ask for the missing secret. Do not silently bypass
  the test.
- Test behavior, business rules, ranking outcomes, safety gates, and meaningful
  regressions. Do not test self-evident language, framework, or library
  behavior.
- Every valuable test should answer: what business requirement would be broken
  if this failed?
- Keep setup compact and readable. If a helper does not reduce real repetition
  or clarify the test's intent, do not add it.

## Test Shape

- Same-code-path cases extend an existing test — new assertion, parametrize
  case, additional matrix value (field mappings, role-based cases, boundary
  values, business-rule matrices). A new test is right when setup,
  behavior-under-test, or business outcome is meaningfully different; in
  particular, don't parametrize when cases would become harder to understand
  combined. Bot-driven review loops compound near-duplicates; reach for
  extend-or-parametrize first.
- Test docstrings should explain business value, not restate mechanics. Prefer
  "Ensures incoming messages are queued so worker downtime does not drop them"
  over "Tests POST /webhook returns 200." One story per contract: a regression
  narrative earns a header/docstring when it names the mechanism the asserts
  pin; per-assertion narration that restates each assert is noise — when every
  assertion has a comment, the load-bearing ones vanish. (Composes with
  `CODING_STANDARDS.md` § Anti-Bloat's invariant-comment-vs-test trade-off —
  the good comment states the constraint, once.)
- **Cap the docstring at two lines, and never re-argue the rationale the code
  already carries.** `CODING_STANDARDS.md` § Concise Code exempts docstrings
  from its 3-line in-body comment ceiling; a *test* docstring is the named
  exception, capped tighter still, because the test name already states the
  contract and the docstring only has to say why it matters. A docstring that re-derives the design argument is the third copy of
  prose that already exists in the module and the PR body. Tell:
  `plow-pbc/agent-mgr#34`'s three test docstrings restated the same three facts
  a third time, at 4-5 lines each.
- Compute expected values through the domain formatter or canonical source when
  appropriate. Avoid brittle hardcoded strings copied from formatter output.

Example of clone-bloat (four near-identical tests for variants of one rule):

```swift
func testRoutingTargetFailedIsSurfaced() { /* 20 LOC build snapshot; assert .containerFailed */ }
func testRoutingTargetBootableReturnsNil() { /* 20 LOC build snapshot; assert nil */ }
func testRoutingTargetDisabledReturnsNil() { /* 20 LOC build snapshot; assert nil */ }
func testNoRoutingTargetReturnsNil() { /* 20 LOC build snapshot; assert nil */ }
```

Same arrange/act shape, four different inputs → expected outcomes. Should be
one table-driven test named after the contract:

```swift
func testUnbootableRoutingTargetFailureCases() {
    let cases: [(name: String, snapshot: Snapshot, plan: Plan, expected: BootError?)] = [
        ("failed routing target → surface containerFailed", failedSnapshot, emptyPlan, .containerFailed(...)),
        ("bootable in plan → nil (executor handles failures)", startingSnapshot, planWith(id), nil),
        ("user-disabled → nil (intentional, not a failure)", disabledSnapshot, emptyPlan, nil),
        ("no routing target → nil", emptySnapshot, emptyPlan, nil),
    ]
    for c in cases {
        XCTAssertEqual(unbootableRoutingTargetFailure(in: c.snapshot, plan: c.plan), c.expected, "[\(c.name)]")
    }
}
```

The table names each case in prose ("failed routing target → surface
containerFailed") so the input→output rule is readable as a whole, and the
assertion is a single line. If the expected type isn't `Equatable`, write a
small one-line comparator — don't fall back to N hand-rolled tests.

## Mocking

- Mock external boundaries in unit and integration tests when the external
  service is not the behavior under test.
- Keep mocks targeted. Avoid long mock chains that mirror implementation
  details.
- Do not assert that a mock returned the value you configured it to return;
  assert the behavior that depends on that value.

## Test Types

- Unit tests isolate complex business logic with fake or in-memory dependencies
  and mocked external services.
- Integration tests verify component interaction and endpoint contracts with
  fast local dependencies and mocked external services.
- E2E mocked tests verify complete workflows with real internal infrastructure
  where needed and mocked external services.
- E2E live tests use real external APIs. They should cover only critical prompt
  or provider behavior, avoid mocks for the live boundary, and cache expensive
  calls where practical.
- Smoke tests should validate deployed system health through public boundaries,
  usually HTTP-only.

## Validation Commands

- Use the repository's test runner, usually `just test`, as the full validation
  command.
- Use fast commands such as `just test-fast` only for iteration. If only the
  fast suite ran, say so plainly and do not claim full tests pass.
- Do not use raw `pytest` when the repo documents a wrapper command; wrappers
  often handle linting, env loading, database setup, secret scanning, or live
  test prerequisites.
- Run the narrowest meaningful command during iteration, then the full bar
  before presenting changed code when feasible.
- If only docs or static assets changed, state that tests were not run.

## Failure Workflow

1. Read the failure and identify what the test expected versus what happened.
2. Fix the root cause: broken code, stale fixture, missing config, service not
   running, or incorrect environment.
3. Rerun the relevant test command.
4. Run the full repository validation command before reporting done when
   feasible.
