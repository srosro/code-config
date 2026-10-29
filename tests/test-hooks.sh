#!/usr/bin/env bash
set -u
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
HOOKS="$HERE/../claude/hooks"

# capture-answer.sh — PostToolUse[AskUserQuestion]: valid JSON, exit 0, right event + nudge
out=$(printf '{"tool_name":"AskUserQuestion","tool_input":{}}' | "$HOOKS/capture-answer.sh"); rc=$?
assert_rc 0 "$rc" "capture-answer exits 0"
printf '%s' "$out" | jq -e . >/dev/null 2>&1; assert_rc 0 $? "capture-answer emits valid JSON"
assert_eq "PostToolUse" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "capture-answer event name"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$ctx" "feedback memory" "capture-answer nudges a feedback memory"
assert_contains "$ctx" "Why:" "capture-answer asks for Why"
assert_contains "$ctx" "How to apply:" "capture-answer asks for How to apply"
assert_contains "$ctx" "paraphrased" "capture-answer prefers paraphrased evidence (no raw capture)"
assert_contains "$ctx" "omit any secret" "capture-answer says to omit secrets/PII"

# capture-prompt.sh — UserPromptSubmit: valid JSON, exit 0, right event + nudge
out=$(printf 'go with the simpler version' | "$HOOKS/capture-prompt.sh"); rc=$?
assert_rc 0 "$rc" "capture-prompt exits 0"
printf '%s' "$out" | jq -e . >/dev/null 2>&1; assert_rc 0 $? "capture-prompt emits valid JSON"
assert_eq "UserPromptSubmit" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "capture-prompt event name"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$ctx" "feedback memory" "capture-prompt nudges a feedback memory"
assert_contains "$ctx" "paraphrased" "capture-prompt prefers paraphrased evidence (no raw capture)"

# Both scripts executable
[ -x "$HOOKS/capture-answer.sh" ]; assert_rc 0 $? "capture-answer is executable"
[ -x "$HOOKS/capture-prompt.sh" ]; assert_rc 0 $? "capture-prompt is executable"

# Fragment: registers all hooks, portable $HOME path, NOT $CLAUDE_PROJECT_DIR
frag="$HOOKS/hooks.settings.json"
jq -e '.hooks.PostToolUse[0].matcher=="AskUserQuestion"' "$frag" >/dev/null 2>&1; assert_rc 0 $? "fragment: PostToolUse matches AskUserQuestion"
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command' "$frag" >/dev/null 2>&1; assert_rc 0 $? "fragment: UserPromptSubmit registered"
cmds=$(jq -r '.hooks[][]?.hooks[].command' "$frag")
assert_contains "$cmds" '$HOME/.claude/hooks/' "fragment: portable \$HOME path"
assert_not_contains "$cmds" 'CLAUDE_PROJECT_DIR' "fragment: no \$CLAUDE_PROJECT_DIR (resolves to wrong project)"

# secret-scan.py — --scan-file mode: the canonical SECRET_PATTERNS source.
# Gates the /cleanup findings file before its direct-to-main commit. Must exit
# 1 on a known secret shape, 0 on clean, and NEVER echo the matched value
# (CLAUDE.md § Secrets).
SCAN="$HOOKS/secret-scan.py"
[ -x "$SCAN" ]; assert_rc 0 $? "secret-scan.py is executable"
scan_clean=$(mktemp)
printf 'clean findings; masked refs sk-…xY7, password=…2pw, <redacted private key …123>, and https://example.com?contact=user:x@y.com are fine\n' > "$scan_clean"
"$SCAN" --scan-file "$scan_clean" >/dev/null 2>&1; assert_rc 0 $? "--scan-file: clean file passes"
"$SCAN" --scan-file "$HERE/../claude/PROPOSALS.md" >/dev/null 2>&1
assert_rc 0 $? "--scan-file: the existing Track B corpus remains committable"
for spec in \
  'AWS key|leaked AKIAIOSFODNN7EXAMPLE here|AKIAIOSFODNN7EXAMPLE' \
  'PEM private key|-----BEGIN OPENSSH PRIVATE KEY-----|BEGIN OPENSSH' \
  'GitHub fine-grained PAT|token github_pat_11ABCDE0aBcDeFgHiJ_kLmNoPqRsTuVwXyZ0123456789AbCdEfGhIjKl|github_pat_11ABCDE' \
  'Stripe live secret key|token sk_live_AAAAAAAAAAAAAAAAAAAAAAAA|sk_live_AAAAA' \
  'Stripe restricted key|token rk_live_BBBBBBBBBBBBBBBBBBBBBBBB|rk_live_BBBBB' \
  'Basic authorization|Authorization: Basic dTpw|dTpw' \
  'quoted Basic authorization|-H '\''Authorization: Basic dTpw'\''|dTpw' \
  'JSON Basic authorization|"Authorization": "Basic dTpw"|dTpw' \
  'short padded Basic authorization|Authorization: Basic Og==|Og==' \
  'quoted assignment with separator|password='\''abcd;efgh'\''|abcd;efgh' \
  'Bash quoted assignment|password=$'\''alpha;BASHTAIL'\''|BASHTAIL' \
  'escaped quoted assignment|password="bravo\\"ESCAPETAIL"|ESCAPETAIL' \
  'unterminated quoted assignment|password='\''charlie;UNTERMINATEDTAIL|UNTERMINATEDTAIL' \
  'incomplete quoted mask|password='\''…***;MASKTAIL'\''|MASKTAIL' \
  'unterminated before newline|password='\''delta;LINETAIL\nnext line|LINETAIL' \
  'unterminated before CRLF|password="echo;CRLFTAIL\r\nnext line|CRLFTAIL' \
  'unterminated before bare CR|password='\''foxtrot;BARECRTAIL\rnext line|BARECRTAIL' \
  'short URL password|postgres://user:abc@db.local/app|abc@db.local' \
  'password-only URL authority|redis://:abc@cache.local/0|abc@cache.local' \
  'short unquoted assignment|password=abc|abc' \
  'short Bearer credential|Authorization: Bearer abc|abc' \
  'generic long Bearer credential|Bearer abcdefgh|abcdefgh' \
  'short Bearer before parenthesis|Authorization: Bearer abc)|abc)' \
  'short Bearer before Markdown delimiter|Authorization: Bearer abc`|abc`' \
  'incomplete mask|password=…hunter2pw|hunter2pw'
do
  IFS='|' read -r label payload leaked <<<"$spec"
  payload=${payload//\\r/$'\r'}
  payload=${payload//\\n/$'\n'}
  scan_file=$(mktemp); printf '%s\n' "$payload" > "$scan_file"
  scan_out=$("$SCAN" --scan-file "$scan_file" 2>&1); rc=$?
  assert_rc 1 "$rc" "--scan-file: $label aborts"
  assert_not_contains "$scan_out" "$leaked" "--scan-file: never echoes $label"
  rm -f "$scan_file"
done
rm -f "$scan_clean"

# The roborev context bridge consumes the same registry before putting review
# text back into an agent's context. A newly registered shape must therefore be
# redacted here without a second hook-specific pattern list.
redacted=$(python3 - "$HOOKS" <<'PY'
import importlib.util
import pathlib
import sys

hook = pathlib.Path(sys.argv[1]) / "roborev-pre-commit-context.py"
spec = importlib.util.spec_from_file_location("roborev_pre_commit_context", hook)
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(hook.parent))
spec.loader.exec_module(module)
print(module._redact_secrets("review quoted sk_live_AAAAAAAAAAAAAAAAAAAAAAAA; password=abcd\n-----BEGIN PRIVATE KEY-----\nabcd\nefg"))
PY
)
assert_not_contains "$redacted" "sk_live_AAAAAAAAAAAAAAAAAAAAAAAA" "roborev context: shared Stripe shape is redacted"
assert_contains "$redacted" "…AAA" "roborev context: redaction retains only the final three characters"
assert_not_contains "$redacted" "…bcd" "roborev context: short assigned secrets reveal no credential characters"
assert_not_contains "$redacted" "…efg" "roborev context: short multiline PEM bodies reveal no credential characters"

# All three roborev hooks share the Claude Bash-request envelope decoder. The
# context bridge is silent when the optional roborev binary is absent on a base
# install; absence is not a broken installation.
python3 - "$HOOKS" <<'PY'
import contextlib
import importlib.util
import io
import pathlib
import sys

hooks = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(hooks))
from _roborev_hooklib import _read_bash_request

sys.stdin = io.StringIO('{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"/tmp"}')
assert _read_bash_request() == ("git push", "/tmp")
sys.stdin = io.StringIO('{"tool_name":"Read","tool_input":{}}')
assert _read_bash_request() is None

hook = hooks / "roborev-pre-commit-context.py"
spec = importlib.util.spec_from_file_location("roborev_pre_commit_context", hook)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module._find_roborev = lambda: None
sys.stdin = io.StringIO('{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"/tmp"}')
stdout = io.StringIO()
with contextlib.redirect_stdout(stdout):
    assert module.main() == 0
assert stdout.getvalue() == ""
PY
assert_rc 0 $? "roborev hooks: shared request decoder and optional-binary silence"

# A clear current branch allows silently. Machine-wide backlog visibility is an
# explicit operator action (`roborev-list-all.py`), not context injected into
# every unrelated push.
python3 - "$HOOKS" <<'PY'
import contextlib
import importlib.util
import io
import pathlib
import sys

hooks = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(hooks))
import _roborev_hooklib

_roborev_hooklib.open_fail_backlog = lambda: [
    {"repo": "other", "root_path": "/tmp/other", "branch": "stale", "id": 7}
]
hook = hooks / "roborev-pre-push-gate.py"
spec = importlib.util.spec_from_file_location("roborev_pre_push_gate", hook)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module._read_bash_request = lambda: ("git push", "/tmp/current")
module._resolve_repo_cwd = lambda *_: "/tmp/current"
module._inside_git_repo = lambda *_: True
module._current_branch = lambda *_: "main"
module._git_toplevel = lambda *_: "/tmp/current"
module._find_roborev = lambda: "/tmp/roborev"
module._list_jobs = lambda *_: []
stdout = io.StringIO()
with contextlib.redirect_stdout(stdout):
    assert module.main() == 0
assert stdout.getvalue() == ""
PY
assert_rc 0 $? "roborev pre-push: clear branch does not inject machine-wide backlog"

roborev_skill=$(cat "$HERE/../claude/skills/roborev/SKILL.md")
assert_not_contains "$roborev_skill" "surfaces this same backlog automatically" "roborev skill: no automatic backlog claim"
assert_not_contains "$roborev_skill" "the commit blocks" "roborev skill: no false close-and-commit claim"
global_guidance=$(cat "$HERE/../claude/CLAUDE.md")
assert_not_contains "$global_guidance" "the commit blocks" "global guidance: no false commit-gate claim"
assert_contains "$global_guidance" "commit hook only warns" "global guidance: names the actual commit boundary"

assert_summary
