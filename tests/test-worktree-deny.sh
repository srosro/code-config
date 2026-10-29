#!/usr/bin/env bash
# The worktree hard stop ships as data for both agents: a Codex execpolicy rule
# and a Claude settings deny. Both must forbid `git worktree add` (creation) and
# leave remove/list/prune alone (cleanup needs them).
set -u
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
ROOT="$HERE/.."
RULES="$ROOT/codex/rules/no-worktree.rules"
DENY="$ROOT/claude/settings.deny.json"

# --- Claude deny fragment: git worktree add only ---
deny=$(jq -r '.permissions.deny[]' "$DENY")
assert_contains "$deny" "Bash(git worktree add:*)" "claude deny: blocks git worktree add"
assert_not_contains "$deny" "worktree remove" "claude deny: does NOT block git worktree remove"
assert_not_contains "$deny" "worktree list" "claude deny: does NOT block git worktree list"

# --- Codex rules: static shape ---
assert_contains "$(cat "$RULES")" 'decision = "forbidden"' "codex rules: forbidden decision"
assert_contains "$(cat "$RULES")" '["git", "worktree", "add"]' "codex rules: matches git worktree add prefix"

# --- Codex rules: live execpolicy verdicts (skip if codex absent) ---
if command -v codex >/dev/null 2>&1; then
  verdict() { codex execpolicy check --rules "$RULES" -- $1 2>/dev/null | jq -r '.decision // "none"'; }
  assert_eq "forbidden" "$(verdict 'git worktree add ../plow-x')" "execpolicy: forbids worktree add"
  assert_eq "forbidden" "$(verdict 'git worktree add -b feat/x ../plow-x origin/main')" "execpolicy: forbids worktree add -b"
  assert_eq "none" "$(verdict 'git worktree remove ../plow-x')" "execpolicy: allows worktree remove"
  assert_eq "none" "$(verdict 'git worktree list')" "execpolicy: allows worktree list"
  assert_eq "none" "$(verdict 'git status')" "execpolicy: ignores unrelated git commands"
else
  echo "note: codex CLI absent — skipped live execpolicy checks (static shape still asserted)"
fi

assert_summary
