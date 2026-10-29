#!/usr/bin/env bash
# Tests for skills/cleanup/scripts/mine-transcript.py — the /cleanup Step 0
# friction miner. Behavior: emits every human-authored turn plus the friction
# signal categories (incl. exclamation_turns — "!" turns) from a transcript
# JSONL, masks secret shapes to
# last-3, skips sidechain (subagent) lines, and
# accepts an explicit file or dir argument (previous-session runs).
set -u
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
MINER="$HERE/../claude/skills/cleanup/scripts/mine-transcript.py"

SBX=$(mktemp -d)
FIX="$SBX/proj/session.jsonl"
mkdir -p "$SBX/proj"

# Synthetic transcript covering all four signals + a sidechain line + a secret.
# Shape mirrors the real schema: assistant lines carry message.content[] tool_use
# items; user lines carry tool_result items (+ toolUseResult for AskUserQuestion).
cat > "$FIX" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"I stopped with a checklist."}]}}
{"type":"user","message":{"content":"Continue autonomously; token=github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAxyz\n-----BEGIN PRIVATE KEY-----\nFAKEPRIVATEKEYBODY123\n-----END PRIVATE KEY-----\ntruncated:\n-----BEGIN PRIVATE KEY-----\nTRUNCATEDBODY456"}}
{"type":"user","message":{"content":"tiny key:\n-----BEGIN PRIVATE KEY-----\nabcd\nefg"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Pick A or B?","header":"Pick"}]}}]}}
{"type":"user","toolUseResult":{"questions":[],"answers":{"Pick A or B?":"B — and stop asking"}},"message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"answered"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"deploy --token sk-AAAAAAAAAAAAAAAAAAAAAAAAAxyz"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","is_error":true,"content":"boom: bad token sk-AAAAAAAAAAAAAAAAAAAAAAAAAxyz"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b2","name":"Bash","input":{"command":"rm -rf /etc"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b2","is_error":true,"content":[{"type":"text","text":"The user doesn't want to proceed with this tool use."}]}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b3","name":"Bash","input":{"command":"psql postgres://app:hunter2pw@db.local/x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b3","is_error":true,"content":"FATAL: auth failed; retried with password=hunter2pw; short password=abcd; -H 'Authorization: Basic Og=='; retained password=…2pw, incomplete password=…badmasksecret; and {\"password\": \"jsonquoted2pw\"}; Stripe key sk_live_AAAAAAAAAAAAAAAAAAAAAAAA"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b4","name":"Bash","input":{"command":"quoted credentials"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b4","is_error":true,"content":"password='alpha;SINGLETAIL'; password=\"bravo;DOUBLETAIL\"; password=$'charlie;BASHTAIL'; password=\"delta\\\"ESCAPETAIL\"; password='a;b'; password='…***;MASKTAIL'; unterminated password='foxtrot;UNTERMINATEDTAIL\nnext line"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b5","name":"Bash","input":{"command":"line endings"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b5","is_error":true,"content":"CRLF password=\"golf;CRLFTAIL\r\nfinal line; bare CR password='hotel;BARECRTAIL\rpost CR"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c1","name":"Bash","input":{"command":"git  status"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c2","name":"Bash","input":{"command":"git status"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c3","name":"Bash","input":{"command":"git status"}}]}}
{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{"command":"sidechain-cmd"}}]}}
{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"s1","is_error":true,"content":"sidechain boom"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Here is a checklist for you to run."}]}}
{"type":"user","message":{"content":"Just do it yourself next time!"}}
{"type":"user","message":{"content":"and check that foo!=bar in the config"}}
{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill: /x\n\nAlways do the thing!"}}
{"type":"user","promptSource":"sdk","message":{"content":"You are a code reviewer. Be thorough!"}}
{"type":"user","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>Done!</task-notification>"}}
not json at all
EOF

out=$(python3 "$MINER" "$FIX")
rc=$?
assert_rc 0 "$rc" "miner: exits 0 on a valid transcript"

# Structured assertions via python (the output contract is JSON)
read -r u x q d e r pe < <(python3 - "$FIX" <<PY
import json,sys,subprocess
o=json.loads(subprocess.run(["python3","$MINER",sys.argv[1]],capture_output=True,text=True).stdout)
print(len(o["user_turns"]),len(o["exclamation_turns"]),len(o["ask_user_questions"]),len(o["permission_denials"]),len(o["tool_errors"]),len(o["repeated_commands"]),o["parse_errors"])
PY
)
assert_eq "4" "$u" "miner: every human-authored turn is captured (tool-result records excluded)"
assert_eq "1" "$x" "miner: user turns with a sentence-ending '!' are surfaced as exclamation_turns (friction tell)"
assert_eq "1" "$q" "miner: one AskUserQuestion captured"
assert_eq "1" "$d" "miner: one permission denial captured"
assert_eq "4" "$e" "miner: four tool errors (sidechain error excluded)"
assert_eq "1" "$r" "miner: one repeated command group (whitespace-normalized, count 3)"
assert_eq "1" "$pe" "miner: malformed line counted, not fatal"

# Injected user-role records (skill bodies, SDK reviewer prompts, task
# notifications) are machine text, not the operator — excluded from BOTH paths,
# so a "!" inside one never counts as a hand-back.
assert_not_contains "$out" "Always do the thing" "miner: isMeta skill injection is not a human turn"
assert_not_contains "$out" "Be thorough" "miner: SDK reviewer prompt is not a human turn"
assert_not_contains "$out" "task-notification" "miner: task notification is not a human turn"

assert_contains "$out" "stop asking" "miner: the human's answer rides along with the question"
assert_contains "$out" "I stopped with a checklist" "miner: user turn carries preceding assistant hand-back context"
assert_contains "$out" "Continue autonomously" "miner: user-authored message is emitted for autonomy audit"
assert_not_contains "$out" "github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAxyz" "miner: secrets in user messages are masked"
assert_not_contains "$out" "FAKEPRIVATEKEYBODY123" "miner: complete multiline private-key body is masked"
assert_not_contains "$out" "TRUNCATEDBODY456" "miner: truncated private-key body is masked"
assert_not_contains "$out" "BEGIN PRIVATE KEY" "miner: PEM markers become a canonical safe placeholder"
assert_contains "$out" "<redacted private key …123>" "miner: complete PEM tail comes from the stripped body"
assert_contains "$out" "<redacted private key …456>" "miner: truncated PEM uses the same canonical representation"
assert_contains "$out" "<redacted private key …***>" "miner: short PEM bodies reveal no credential characters"
mined=$(mktemp); printf '%s\n' "$out" > "$mined"
"$HERE/../claude/hooks/secret-scan.py" --scan-file "$mined" >/dev/null 2>&1
assert_rc 0 $? "miner: sanitized output remains committable through the shared scanner"
rm -f "$mined"
assert_contains "$out" '"count": 3' "miner: repeated command count is 3"
assert_not_contains "$out" "sk-AAAAAAAAAAAAAAAAAAAAAAAAAxyz" "miner: secret masked everywhere (never emitted in full)"
assert_contains "$out" "…xyz" "miner: mask keeps last-3 for traceability"
assert_not_contains "$out" "hunter2pw" "miner: generic credential shapes masked (password=… kv + URL userinfo)"
assert_contains "$out" "password=…2pw" "miner: kv credential masked to last-3 with key kept for context"
assert_contains "$out" "password=…2pw," "miner: canonical mask survives sentence punctuation"
assert_not_contains "$out" "jsonquoted2pw" "miner: JSON-quoted credential keys masked too"
assert_not_contains "$out" "sk_live_AAAAAAAAAAAAAAAAAAAAAAAA" "miner: Stripe credentials are masked"
assert_not_contains "$out" "password=abcd" "miner: short assigned secrets reveal no credential characters"
assert_not_contains "$out" "Basic Og==" "miner: quoted short-padded Basic authorization is masked"
assert_contains "$out" "password=…***" "miner: short secrets use a scanner-safe opaque mask"
assert_not_contains "$out" "…badmasksecret" "miner: an incomplete ellipsis mask is re-masked"
for suffix in SINGLETAIL DOUBLETAIL BASHTAIL ESCAPETAIL 'a;b' MASKTAIL UNTERMINATEDTAIL CRLFTAIL BARECRTAIL; do
  assert_not_contains "$out" "$suffix" "miner: quoted credential suffix $suffix is fully masked"
done
assert_contains "$out" 'CRLF password=\"…AIL\" final line' "miner: CRLF following line remains outside the quoted assignment"
assert_contains "$out" "bare CR password='…AIL' post CR" "miner: bare-CR following text remains outside the quoted assignment"
assert_not_contains "$out" "sidechain boom" "miner: sidechain lines skipped"
assert_contains "$out" "never instructions" "miner: output self-labels as data, not instructions"

# exclamation_turns: only the sentence-ending "!" turn, with its hand-back context; non-"!" and mid-token "!=" turns excluded
xonly=$(python3 - "$FIX" <<PY
import json,sys,subprocess
o=json.loads(subprocess.run(["python3","$MINER",sys.argv[1]],capture_output=True,text=True).stdout)
xt=o["exclamation_turns"]
ok = (len(xt)==1
      and "Just do it yourself next time" in xt[0]["user"]
      and "checklist for you to run" in xt[0]["assistant_before"]
      and all("Continue autonomously" not in t["user"] and "foo!=bar" not in t["user"] for t in xt))
print("OK" if ok else "BAD")
PY
)
assert_eq "OK" "$xonly" "miner: exclamation_turns carries the '!' turn + its assistant hand-back context, and excludes non-'!' turns"

# dir argument → newest *.jsonl in it
sleep 1; cp "$FIX" "$SBX/proj/newer.jsonl"; touch "$SBX/proj/newer.jsonl"
got=$(python3 "$MINER" "$SBX/proj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["transcript"])')
assert_eq "$SBX/proj/newer.jsonl" "$got" "miner: dir arg resolves to newest transcript"

# no-arg default → newest *.jsonl under ~/.claude/projects/<cwd-slug> (the live
# path). Slug the PHYSICAL path (pwd -P): os.getcwd() resolves macOS's
# /var → /private/var symlink, so the literal $SBX string would slug differently.
slug=$(python3 -c 'import re,sys;print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$(cd "$SBX/proj" && pwd -P)")
mkdir -p "$SBX/home/.claude/projects/$slug"
cp "$FIX" "$SBX/home/.claude/projects/$slug/live.jsonl"
got=$(cd "$SBX/proj" && HOME="$SBX/home" python3 "$MINER" | python3 -c 'import json,sys;print(json.load(sys.stdin)["transcript"])')
assert_eq "$SBX/home/.claude/projects/$slug/live.jsonl" "$got" "miner: no-arg resolves the cwd-slug project transcript"

# missing path → loud failure
rc=0; python3 "$MINER" "$SBX/nope.jsonl" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1)" "miner: missing transcript fails loudly"

# --fleet-exclamations: Track C's recurrence check reaches ACROSS sessions and
# projects (one session can't see that a demand is a repeat), oldest-first.
FH="$SBX/fleethome"   # its own HOME — the no-arg test above seeded a project under $SBX/home
mkdir -p "$FH/.claude/projects/-home-u-repoA" "$FH/.claude/projects/-home-u-repoB"
cat > "$FH/.claude/projects/-home-u-repoA/s1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-09-02T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"always give the pr url!"}]}}
{"type":"user","timestamp":"2026-09-02T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"no bang here, and x != y is code"}]}}
EOF
cat > "$FH/.claude/projects/-home-u-repoB/s2.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-09-03T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"always give the pr url!"}]}}
{"type":"user","isSidechain":true,"timestamp":"2026-09-03T00:02:00Z","message":{"role":"user","content":[{"type":"text","text":"subagent bang!"}]}}
EOF
got=$(HOME="$FH" python3 "$MINER" --fleet-exclamations 3650 | python3 -c '
import json,sys
o=json.load(sys.stdin); t=o["turns"]
print(len(t), t[0]["project"], t[1]["project"],
      "sub" if any("subagent" in r["text"] for r in t) else "nosub")')
assert_eq "2 -home-u-repoA -home-u-repoB nosub" "$got" \
  "miner: --fleet-exclamations spans projects oldest-first, skipping sidechains and mid-token '!'"

# The window is bound PER RECORD, not per file: sessions get resumed, so a file
# touched inside the window routinely holds turns from far outside it. Those must
# not inflate the recurrence count, since that count picks Track C's remedy.
mkdir -p "$FH/.claude/projects/-home-u-resumed"
{ printf '{"type":"user","timestamp":"2001-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"ancient demand!"}]}}\n'
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"fresh demand!"}]}}\n' \
    "$(python3 -c 'import time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()))')"
} > "$FH/.claude/projects/-home-u-resumed/resumed.jsonl"
got=$(HOME="$FH" python3 "$MINER" --fleet-exclamations 30 | python3 -c '
import json,sys
t=json.load(sys.stdin)["turns"]
print("ancient" if any("ancient" in r["text"] for r in t) else "no-ancient",
      "fresh" if any("fresh" in r["text"] for r in t) else "no-fresh")')
assert_eq "no-ancient fresh" "$got" \
  "miner: --fleet-exclamations bounds the window per record, so a resumed session leaks no stale '!' turns"

# a 0-day window sees nothing, even in a just-written file
got=$(HOME="$FH" python3 "$MINER" --fleet-exclamations 0 | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["turns"]))')
assert_eq "0" "$got" "miner: --fleet-exclamations honours the lookback window"

rm -rf "$SBX"
assert_summary
