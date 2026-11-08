#!/usr/bin/env bash
set -u
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
HOOKS="$HERE/../claude/hooks"

# The roborev gates and memory-capture nudges moved to kitchen (kitchen setup owns them);
# the files left here are forwarders for stale settings entries and memorized paths.
for f in roborev-pre-commit-context.py roborev-pre-push-gate.py roborev-pre-checkout-gate.py roborev-list-all.py capture-answer.sh capture-prompt.sh; do
  [ -x "$HOOKS/$f" ]; assert_rc 0 $? "$f forwarder is executable"
  assert_contains "$(cat "$HOOKS/$f")" "services/kitchen/src/claude_kitchen/hooks/$f" "$f forwards to kitchen's copy"
done
# Fragment: only the hooks this repo still owns, portable $HOME path, NOT $CLAUDE_PROJECT_DIR
frag="$HOOKS/hooks.settings.json"
cmds=$(jq -r '.hooks[][]?.hooks[].command' "$frag")
assert_eq '$HOME/.claude/hooks/knightwatch-inflight-push-gate.py' "$cmds" "fragment: only the knightwatch gate (kitchen owns the rest)"
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

global_guidance=$(cat "$HERE/../claude/CLAUDE.md")
assert_not_contains "$global_guidance" "the commit blocks" "global guidance: no false commit-gate claim"
assert_contains "$global_guidance" "commit hook only warns" "global guidance: names the actual commit boundary"

assert_summary
