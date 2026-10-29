#!/usr/bin/env python3
"""PreToolUse[Bash] gate — when a `git push` OR a `/srosro-*review` re-review
trigger is about to run while a knightwatch review is in flight on this branch's
PR, DENY it and hand the judgment to the LLM: wait for the review, or proceed
once it's done. Both are ways to perturb a running review — a push stales the
snapshotted head, a trigger stacks a second (possibly-stale) review behind it —
so the latch covers both, not just the push (see plow-pbc/knightwatch-reviewer's
#1102, where a babysit `/srosro-review` stacked on a running review).

This enforces babysit-pr's in-flight latch for EVERY agent — main loop and
dispatched subagents alike (a subagent obeys this hook the way it already obeys
the roborev pre-push gate). It's the fix for plow#1036, where a subagent pushed
straight into a running review because the latch was prose only the main loop read.

Deliberately dumb. It does NOT parse the gh/jq command and does NOT reimplement
the reviewer's lifecycle. An outgoing TRIGGER is identified by the
`KNIGHTWATCH_REVIEW_TRIGGER=1` marker the babysit prefixes onto EVERY trigger post
(see REVIEW_TRIGGER_MARKER) — no shell-command classifier, because at this
single-operator point the babysit is the only producer of these triggers, so a
self-identifying marker is exact and far smaller than parsing every gh variant. A
PUSH is the `git push` substring. "In flight" is the reviewer's live placeholder —
a bot auto-post whose visible content LEADS with `👀 reviewing` (see
`_is_live_starter`). The reviewer POSTs it at run-start and DELETEs it on
completion (an aborted/orphaned one self-heals: the next run on this PR reuses
then deletes it), so its presence means "a run owns this PR." The brief
queued-before-placeholder window (a trigger posted before its review starts) is
deliberately NOT modeled: correlating a completion timestamp to the run it belongs
to isn't reliable from comments alone (an earlier run can land after a later
trigger), so that state machine is race-prone — the cooperative prose latch +
landing-side coverage verification cover that window. The *judgment* — wait vs
proceed vs return review-ready-local — lives in the deny text for the LLM, not in
branchy Python.

Trust + safety: only the review bot's OWN live placeholder counts, so a PR
participant can't spoof "in flight." NO comment body is echoed into the LLM-facing
deny reason (a PR comment is untrusted → prompt-injection surface).

Scope: it queries the PR for the hook's cwd, for BOTH gates. A standalone `git
push` (cwd = the repo) is the contract; a `cd other-repo && git push` is scoped
to cwd, not the target — fail-open on that cross-repo form, a rare shape not
worth a parser. Triggers are cwd-scoped the same way: the babysit posts a
trigger for the PR it is babysitting, from that PR's checkout (cwd == target),
so a trigger that explicitly names a *different* PR than cwd's branch is the same
documented cwd-scope gap — not parsed out of the command.

FAIL-OPEN: any error (no gh, no PR, network, unparseable) allows the push — a
broken gh must never wedge pushes fleet-wide, and review staleness is recoverable.
"""
import json
import re
import subprocess
import sys

BOT_USER = "srosro"  # the review bot signs its posts as this login
AUTO_POST_MARKER = "<!-- knightwatch-reviewer:auto-post -->"  # on every bot auto-post
REVIEWING_TOKEN = "👀 reviewing"  # a live starter's visible content leads with this
# The env-var marker the babysit prefixes onto every trigger post (see module
# docstring for why this replaces a command parser).
REVIEW_TRIGGER_MARKER = "KNIGHTWATCH_REVIEW_TRIGGER=1"
_HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def _is_live_starter(c: dict) -> bool:
    """A bot auto-post whose VISIBLE content (HTML comments stripped) *leads* with
    `👀 reviewing`. Checking the lead — not mere presence of a marker/token — is
    what keeps a comment that merely *quotes* them (a completed 📋 review, a
    babysit reply) from false-matching and wedging pushes; only the reviewer's
    live placeholder starts this way, and it's DELETED on completion."""
    if (c.get("author") or {}).get("login") != BOT_USER:
        return False
    body = c.get("body") or ""
    if AUTO_POST_MARKER not in body:
        return False
    return _HTML_COMMENT.sub("", body).lstrip().startswith(REVIEWING_TOKEN)


# No comment body is interpolated into these reasons — they go to the LLM, and a
# PR comment is untrusted (a participant could otherwise inject instructions).
PUSH_REASON = (
    "Push blocked: a knightwatch review is IN FLIGHT on this PR (the review bot has "
    "a live '👀 reviewing' placeholder up). Pushing now risks review thrash: it "
    "stales the running ~20-40 min review and can spawn an overlapping re-run.\n\n"
    "Assess and act:\n"
    "  - If a review is actively running: set a ~20-min ScheduleWakeup, let it "
    "land, address the feedback, THEN push.\n"
    "  - If you are a dispatched subagent (can't self-schedule): commit and return "
    "review-ready-LOCAL so the main loop pushes on the next wake.\n"
    "  - If you believe the review already finished: the reviewer deletes the "
    "placeholder on completion, so re-check `gh pr view` — if it's gone, re-push."
)
TRIGGER_REASON = (
    "Re-review trigger blocked: a knightwatch review is already IN FLIGHT on this "
    "PR (the review bot has a live '👀 reviewing' placeholder up). Posting a "
    "/srosro-review or /srosro-update-review now STACKS a second review behind the "
    "running one — it reviews a possibly-stale head and deepens the ~40-min-per-slot "
    "queue.\n\n"
    "Assess and act:\n"
    "  - Let the running review land first (set a ~20-min ScheduleWakeup), confirm "
    "it covered the current head, and trigger only if the head advanced since.\n"
    "  - If you are a dispatched subagent (can't self-schedule): return "
    "review-ready-LOCAL so the main loop triggers on the next wake."
)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    command = (payload.get("tool_input") or {}).get("command", "")
    is_push = "git push" in command
    # Only the canonical LEADING env assignment (`KNIGHTWATCH_REVIEW_TRIGGER=1 …`)
    # is a trigger — so a diagnostic/grep that merely mentions the marker isn't gated.
    is_trigger = command.lstrip().startswith(REVIEW_TRIGGER_MARKER + " ")
    if not (is_push or is_trigger):
        return 0
    try:
        r = subprocess.run(
            ["gh", "pr", "view", "--json", "comments"],
            cwd=payload.get("cwd") or ".", capture_output=True, text=True, timeout=20,
        )
        comments = json.loads(r.stdout)["comments"] if r.returncode == 0 else []
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError):
        return 0  # fail-open

    # In flight = a live `👀 reviewing` starter. (Queued-before-placeholder is
    # deliberately unmodeled — see the docstring — and covered by landing-side verify.)
    if any(_is_live_starter(c) for c in comments):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": PUSH_REASON if is_push else TRIGGER_REASON,
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
