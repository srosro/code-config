#!/usr/bin/env bash
# Smoke checks for `just install`. Validates that:
#   - claude/ has at least one *.md doc
#   - claude/skills/ has at least one skill dir, each with a SKILL.md
#   - `just install` against a temp HOME links every doc and skill (with the
#     correct symlink target), is rerun-safe, and leaves no empty backups
#     dir on a clean install
#   - `just install` backs up both a legacy real skill dir AND a legacy real
#     doc file under ~/.claude into ~/.claude/backups/pre-symlink-<ts>/
#     instead of clobbering them
# bash + standard utils only — no third-party deps. Requires `just` on PATH.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Keep the symlink checks offline + side-effect-free: `just install` now also
# provisions the Playwright MCP server and installs the default plugins, which
# we don't want firing against the temp HOMEs below (network, claude CLI,
# browser download, marketplace clones). The setup script's own decision logic
# is covered by check 9.
export CONFIG_SKIP_MCP=1
export CONFIG_SKIP_PLUGINS=1

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

# 1. claude/ has at least one top-level doc
shopt -s nullglob
docs=(claude/*.md)
shopt -u nullglob
[[ ${#docs[@]} -ge 1 ]] || fail "no top-level *.md docs in claude/"
pass "${#docs[@]} top-level docs discovered in claude/"

# 2. Every skill dir has a SKILL.md
shopt -s nullglob
skills=(claude/skills/*/)
shopt -u nullglob
[[ ${#skills[@]} -ge 1 ]] || fail "no skill dirs under claude/skills/"
for d in "${skills[@]}"; do
  [[ -f "$d/SKILL.md" ]] || fail "$d missing SKILL.md"
done
pass "all ${#skills[@]} skill dirs have a SKILL.md"

# 3. `just install` against a clean temp HOME links every doc/skill at the
#    correct target, is rerun-safe, and leaves no empty backups dir.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
HOME="$tmp" just install >/dev/null
HOME="$tmp" just install >/dev/null  # rerun
for d in "${docs[@]}"; do
  name=$(basename "$d")
  [[ -L "$tmp/.claude/$name" ]] || fail "$name not linked under $tmp/.claude/"
  target=$(readlink "$tmp/.claude/$name")
  expected="$PWD/$d"
  [[ "$target" == "$expected" ]] || fail "$tmp/.claude/$name points at '$target', expected '$expected'"
done
for d in "${skills[@]}"; do
  name=$(basename "$d")
  [[ -L "$tmp/.claude/skills/$name" ]] || fail "skill $name not linked under $tmp/.claude/skills/"
  target=$(readlink "$tmp/.claude/skills/$name")
  expected="$PWD/${d%/}"
  [[ "$target" == "$expected" ]] || fail "skill $name points at '$target', expected '$expected'"
done
[[ ! -d "$tmp/.claude/backups" ]] || fail "clean install left an empty backups dir at $tmp/.claude/backups"
pass "just install on clean HOME links all docs+skills with correct targets, is rerun-safe, no empty backups dir"

# The git-worktree hard stop lands as a Claude permission deny and survives the
# rerun (idempotent union), scoped to CREATION only so cleanup's remove/list work.
jq -e '.permissions.deny | index("Bash(git worktree add:*)")' "$tmp/.claude/settings.json" >/dev/null \
  || fail "settings.json missing the git worktree add deny"
[[ "$(jq '[.permissions.deny[] | select(. == "Bash(git worktree add:*)")] | length' "$tmp/.claude/settings.json")" == "1" ]] \
  || fail "git worktree add deny not idempotent across rerun"
! jq -e '.permissions.deny[] | select(test("worktree (remove|list|prune)"))' "$tmp/.claude/settings.json" >/dev/null \
  || fail "settings.json wrongly denies git worktree remove/list/prune"
pass "just install adds an idempotent git-worktree-add deny to settings.json (remove/list/prune stay allowed)"

# The aggregate install wires Codex-native guidance and skills. It must not
# import Claude references/skills or replace machine-local Codex state.
[[ -L "$tmp/.codex/AGENTS.md" ]] || fail "Codex AGENTS.md not linked"
[[ "$(readlink "$tmp/.codex/AGENTS.md")" == "$PWD/codex/AGENTS.md" ]] \
  || fail "Codex AGENTS.md points at the wrong source"
for d in codex/skills/*/; do
  name=$(basename "$d")
  [[ -L "$tmp/.agents/skills/$name" ]] || fail "Codex skill $name not linked under ~/.agents/skills"
  [[ "$(readlink "$tmp/.agents/skills/$name")" == "$PWD/${d%/}" ]] \
    || fail "Codex skill $name points at the wrong source"
done
[[ ! -e "$tmp/.codex/references" ]] || fail "Claude references leaked into Codex"
[[ ! -e "$tmp/.codex/skills" ]] || fail "Claude skills leaked into Codex"
[[ ! -e "$tmp/.codex/config.toml" ]] || fail "install created machine-local Codex config.toml"
[[ -L "$tmp/.codex/rules/no-worktree.rules" ]] || fail "Codex worktree execpolicy rule not linked under ~/.codex/rules"
[[ "$(readlink "$tmp/.codex/rules/no-worktree.rules")" == "$PWD/codex/rules/no-worktree.rules" ]] \
  || fail "Codex worktree rule points at the wrong source"
[[ ! -e "$tmp/.codex/rules/default.rules" ]] || fail "install must not own ~/.codex/rules/default.rules (TUI writes there)"
pass "just install wires Codex guidance, native skills, and the worktree execpolicy rule without touching machine-local state"

# A same-name user skill, including a dangling symlink, is recoverable rather
# than silently replaced. Unrelated user skills remain untouched.
tmp_codex_collision="$(mktemp -d)"
mkdir -p "$tmp_codex_collision/.agents/skills"
ln -s "$tmp_codex_collision/missing-cleanup" "$tmp_codex_collision/.agents/skills/cleanup"
mkdir -p "$tmp_codex_collision/user-skill"
ln -s "$tmp_codex_collision/user-skill" "$tmp_codex_collision/.agents/skills/unrelated"
HOME="$tmp_codex_collision" just install-codex >/dev/null
[[ -L "$tmp_codex_collision/.agents/skills/cleanup" ]] || fail "cleanup skill collision was not replaced"
[[ "$(readlink "$tmp_codex_collision/.agents/skills/cleanup")" == "$PWD/codex/skills/cleanup" ]] \
  || fail "cleanup skill collision points at the wrong source"
find "$tmp_codex_collision/.agents/backups" -type l -name cleanup -print -quit | grep -q . \
  || fail "dangling same-name Codex skill was not backed up"
[[ "$(readlink "$tmp_codex_collision/.agents/skills/unrelated")" == "$tmp_codex_collision/user-skill" ]] \
  || fail "unrelated user Codex skill was changed"
rm -rf "$tmp_codex_collision"
pass "Codex skill install preserves collisions and unrelated user skills"

# The online Codex plugin step is tested through the CLI boundary. It must
# refresh the dedicated marketplace at the exact upstream tag, enable that
# plugin, then retire the stale curated distribution.
tmp_codex_plugin="$(mktemp -d)"
mkdir -p "$tmp_codex_plugin/bin"
cat > "$tmp_codex_plugin/bin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CODEX_LOG"
EOF
chmod +x "$tmp_codex_plugin/bin/codex"
plugin_output=$(
  HOME="$tmp_codex_plugin" \
  CODEX_HOME="$tmp_codex_plugin/.codex" \
  CODEX_LOG="$tmp_codex_plugin/calls" \
  CONFIG_SKIP_PLUGINS=0 \
  PATH="$tmp_codex_plugin/bin:$PATH" \
  just install-codex
)
cat > "$tmp_codex_plugin/expected" <<'EOF'
plugin marketplace remove superpowers-dev
plugin marketplace add obra/superpowers --ref b36e0829c6d0140e93cfef2ca599b1b07d4a7797
plugin add superpowers@superpowers-dev
plugin remove superpowers@openai-curated
EOF
cmp -s "$tmp_codex_plugin/expected" "$tmp_codex_plugin/calls" \
  || fail "Codex installer did not install the pinned upstream Superpowers plugin"
grep -qF 'installed Superpowers plugin v6.3.0 at b36e0829c6d0140e93cfef2ca599b1b07d4a7797' <<<"$plugin_output" \
  || fail "Codex installer did not report the pinned Superpowers version"
rm -rf "$tmp_codex_plugin"
pass "Codex installs the pinned upstream Superpowers plugin and retires the stale source"

# 3b. `just install` also symlinks the tc CLI into ~/.local/bin (entrypoint only;
#     lib/fleet.sh + lib/pick.sh resolve relative to the symlink target).
[[ -L "$tmp/.local/bin/tc" ]] || fail "tc not linked under $tmp/.local/bin/"
tc_target=$(readlink "$tmp/.local/bin/tc")
[[ "$tc_target" == "$PWD/tc" ]] || fail "$tmp/.local/bin/tc points at '$tc_target', expected '$PWD/tc'"
pass "just install symlinks the tc CLI into ~/.local/bin"

# 3b-tmux. `just install` symlinks ~/.tmux.conf to the repo file and tic's an
#     xterm-ghostty terminfo entry carrying Hls (OSC 8) into ~/.terminfo — the
#     declarative replacement for tc's removed per-connect terminfo prelude. The
#     double-install in check 3 means a pass also proves the tic guard is
#     idempotent (re-run skips the already-Hls entry without erroring).
[[ -L "$tmp/.tmux.conf" ]] || fail "~/.tmux.conf not linked under $tmp/"
tmux_target=$(readlink "$tmp/.tmux.conf")
[[ "$tmux_target" == "$PWD/tmux.conf" ]] || fail "$tmp/.tmux.conf points at '$tmux_target', expected '$PWD/tmux.conf'"
# Regression guard (PR #116 removed this line; PR #120 restored it): the
# terminal-features override — NOT terminfo Hls — is what makes tmux pass OSC 8
# hyperlinks through. Pin it so a future "terminfo makes it redundant" edit can't
# silently re-drop it green.
grep -qF "set -as terminal-features 'xterm-ghostty:hyperlinks'" "$PWD/tmux.conf" \
  || fail "tmux.conf is missing the 'set -as terminal-features xterm-ghostty:hyperlinks' override — tmux strips OSC 8 hyperlinks without it (terminfo Hls alone does NOT enable passthrough; verified tmux 3.6b)"
# The terminfo install is fail-soft when ncurses' tic is absent (see justfile),
# so gate the assertion the same way — a tic-less runner skips it too, keeping
# test and install on one contract. When tic is present, the check is hermetic:
# assert install actually WROTE the entry into the temp ~/.terminfo (not merely
# that some system-wide entry resolves) and that it carries Hls, with both
# terminfo search vars pinned to the temp dir so a host's own xterm-ghostty
# can't mask a broken install.
if command -v tic >/dev/null 2>&1; then
  ghostty_ti=$(ls "$tmp"/.terminfo/*/xterm-ghostty 2>/dev/null | head -1)
  [[ -n "$ghostty_ti" ]] || fail "just install did not write an xterm-ghostty terminfo entry into ~/.terminfo"
  TERMINFO="$tmp/.terminfo" TERMINFO_DIRS="$tmp/.terminfo" infocmp -x xterm-ghostty 2>/dev/null | grep 'Hls=' >/dev/null \
    || fail "the xterm-ghostty entry just install wrote lacks the Hls (OSC 8) capability"
  pass "just install symlinks ~/.tmux.conf and installs the Hls-bearing xterm-ghostty terminfo"
else
  pass "just install symlinks ~/.tmux.conf (tic absent — terminfo install skipped, matching install's fail-soft path)"
fi

# 3b-cc. `just install` makes `goclaude` (the launcher alias) reach the host's interactive
#        shell: the active shell's rc ($SHELL) always ends up sourcing aliases.sh
#        (created if absent), and a pre-existing secondary rc is covered too. It's an
#        alias, not a ~/.local/bin/goclaude symlink — and deliberately not named `cc`,
#        which would shadow the system C compiler. Matrix covers fresh homes AND the
#        zsh-active/only-.bashrc-exists case (the edge where seeding only existing rcs
#        would miss the active shell).
#        Columns: SHELL | pre-create rcs | rcs that must source goclaude | rcs that must NOT exist.
#        The matrix is read on fd 3 (read -u 3 / done 3<<) so the inner `just install`
#        can't consume CASES lines from stdin and silently truncate the matrix.
grep -q "alias goclaude=" "$PWD/aliases.sh" || fail "aliases.sh does not define the goclaude alias"
grep -q "alias gocodex=.*codex'" "$PWD/aliases.sh" || fail "aliases.sh does not define the gocodex alias"
! grep -q "alias gocodex=.*--yolo" "$PWD/aliases.sh" || fail "gocodex must retain Codex sandbox and approvals"
# Unlike the two loops in tests/, this body runs `just install`, and the child
# inherits fd 3 open — so a child that reads it still truncates this matrix, and
# the `pass` below prints green with nothing behind it. That asymmetry is why
# this counter stays after the two in tests/ were dropped.
cases=0
while IFS='|' read -r -u 3 sh pre want absent; do
  [[ -z "$sh" ]] && continue
  cases=$((cases+1))
  tmp_cc="$(mktemp -d)"
  [[ "$pre" == "-" ]] || for f in $pre; do : > "$tmp_cc/$f"; done
  CONFIG_SKIP_MCP=1 CONFIG_SKIP_PLUGINS=1 SHELL="/bin/$sh" HOME="$tmp_cc" just install >/dev/null
  CONFIG_SKIP_MCP=1 CONFIG_SKIP_PLUGINS=1 SHELL="/bin/$sh" HOME="$tmp_cc" just install >/dev/null  # idempotency
  for f in $want; do
    grep -qF "$PWD/aliases.sh" "$tmp_cc/$f" || fail "[SHELL=$sh pre='$pre'] ~/$f missing goclaude source line"
    [[ "$(grep -cF "$PWD/aliases.sh" "$tmp_cc/$f")" == "1" ]] || fail "[SHELL=$sh pre='$pre'] ~/$f goclaude source line not idempotent"
  done
  [[ "$absent" == "-" ]] || for f in $absent; do
    [[ ! -f "$tmp_cc/$f" ]] || fail "[SHELL=$sh pre='$pre'] ~/$f should not have been created"
  done
  rm -rf "$tmp_cc"
done 3<<'CASES'
bash|-|.bashrc|.zshrc
zsh|-|.zshrc|.bashrc
zsh|.bashrc|.zshrc .bashrc|-
bash|.bashrc .zshrc|.bashrc .zshrc|-
zsh|.bashrc .zshrc|.zshrc .bashrc|-
CASES
[[ "$cases" == 5 ]] || fail "goclaude shell-rc matrix ran $cases of 5 rows — a skipped row would otherwise reach the unconditional pass below"
pass "just install sources goclaude into the active shell's rc on every host (created if absent; secondary rc covered; idempotent)"

# 3b2. The one-time repository-path migration preflights the whole move set,
#      moves occupied legacy paths, rewrites only the installer-owned rc line,
#      and is rerun-safe. A collision aborts before any source moves.
tmp_paths="$(mktemp -d)"
mkdir -p "$tmp_paths/services/claude-config" "$tmp_paths/Hacking/claude-config0" "$tmp_paths/Hacking/claude-config8"
git -C "$tmp_paths/services/claude-config" init -q
git -C "$tmp_paths/services/claude-config" remote add origin git@github.com:srosro/claude-config.git
git -C "$tmp_paths/Hacking/claude-config0" init -q
git -C "$tmp_paths/Hacking/claude-config0" remote add origin https://github.com/srosro/claude-config
old_rc_line=". \"$tmp_paths/services/claude-config/aliases.sh\"  # claude-config fleet aliases"
new_rc_line=". \"$tmp_paths/services/code-config/aliases.sh\"  # code-config fleet aliases"
printf '%s\n%s\n' "$old_rc_line" '. "$HOME/custom-aliases.sh"' > "$tmp_paths/.bashrc"
HOME="$tmp_paths" just migrate-paths >/dev/null
for path in services/code-config Hacking/code-config0 Hacking/code-config8; do
  [[ -d "$tmp_paths/$path" ]] || fail "migrate-paths did not create $path"
done
[[ ! -e "$tmp_paths/services/claude-config" && ! -e "$tmp_paths/Hacking/claude-config0" && ! -e "$tmp_paths/Hacking/claude-config8" ]] \
  || fail "migrate-paths left a moved legacy path behind"
grep -qF "$new_rc_line" "$tmp_paths/.bashrc" || fail "migrate-paths did not rewrite installer-owned rc line"
! grep -qF "$old_rc_line" "$tmp_paths/.bashrc" || fail "migrate-paths left installer-owned legacy rc line"
grep -qF '. "$HOME/custom-aliases.sh"' "$tmp_paths/.bashrc" || fail "migrate-paths changed a user-owned rc line"
[[ "$(git -C "$tmp_paths/services/code-config" remote get-url origin)" == git@github.com:srosro/code-config.git ]] \
  || fail "migrate-paths did not rewrite the SSH origin URL"
[[ "$(git -C "$tmp_paths/Hacking/code-config0" remote get-url origin)" == https://github.com/srosro/code-config.git ]] \
  || fail "migrate-paths did not rewrite the HTTPS origin URL"
HOME="$tmp_paths" just migrate-paths >/dev/null
rm -rf "$tmp_paths"

tmp_collision="$(mktemp -d)"
mkdir -p "$tmp_collision/services/claude-config" "$tmp_collision/services/code-config" "$tmp_collision/Hacking/claude-config0"
if HOME="$tmp_collision" just migrate-paths >/dev/null 2>&1; then
  fail "migrate-paths accepted an existing destination"
fi
[[ -d "$tmp_collision/services/claude-config" && -d "$tmp_collision/Hacking/claude-config0" ]] \
  || fail "migrate-paths moved sources despite a preflight collision"
rm -rf "$tmp_collision"
pass "migrate-paths is collision-safe, complete, remote+rc-scoped, and idempotent"

# 3c. `just install` symlinks the hooks dir and idempotently merges the canonical
#     hooks block into ~/.claude/settings.json. The double-install in check 3 means
#     this also proves the jq merge is rerun-safe (arrays replaced, not duplicated).
[[ -L "$tmp/.claude/hooks" ]] || fail "hooks dir not linked under $tmp/.claude/"
hooks_target=$(readlink "$tmp/.claude/hooks")
[[ "$hooks_target" == "$PWD/claude/hooks" ]] || fail "$tmp/.claude/hooks points at '$hooks_target', expected '$PWD/claude/hooks'"
[[ -f "$tmp/.claude/settings.json" ]] || fail "settings.json not created under $tmp/.claude/"
jq -e '.hooks.PostToolUse[0].matcher=="AskUserQuestion"' "$tmp/.claude/settings.json" >/dev/null \
  || fail "settings.json missing PostToolUse[AskUserQuestion] hook after install"
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command' "$tmp/.claude/settings.json" >/dev/null \
  || fail "settings.json missing UserPromptSubmit hook after install"
n_post=$(jq '.hooks.PostToolUse | length' "$tmp/.claude/settings.json")
[[ "$n_post" == "1" ]] || fail "PostToolUse has $n_post entries after double-install (jq merge not idempotent — should be 1)"
pass "just install links hooks dir + idempotently merges PostToolUse/UserPromptSubmit hooks into settings.json"

# 3d. The settings merge is non-destructive: a user's pre-existing unrelated
#     hooks + top-level keys survive, and re-running install doesn't stack
#     duplicates of our entries. (A plain `jq '*'` deep-merge would array-replace
#     and silently drop the user's other PostToolUse/UserPromptSubmit hooks.)
tmp_pre="$(mktemp -d)"
mkdir -p "$tmp_pre/.claude"
cat > "$tmp_pre/.claude/settings.json" <<'JSON'
{"theme":"dark","hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"echo pre-existing"}]}]}}
JSON
CONFIG_SKIP_MCP=1 HOME="$tmp_pre" just install >/dev/null
CONFIG_SKIP_MCP=1 HOME="$tmp_pre" just install >/dev/null   # rerun → idempotency
jq -e '.theme=="dark"' "$tmp_pre/.claude/settings.json" >/dev/null \
  || fail "settings merge dropped an unrelated top-level key (theme)"
jq -e 'any(.hooks.PostToolUse[]; .matcher=="Edit")' "$tmp_pre/.claude/settings.json" >/dev/null \
  || fail "settings merge dropped the user's pre-existing PostToolUse[Edit] hook"
jq -e 'any(.hooks.PostToolUse[]; .matcher=="AskUserQuestion")' "$tmp_pre/.claude/settings.json" >/dev/null \
  || fail "settings merge didn't add PostToolUse[AskUserQuestion]"
n_aq=$(jq '[.hooks.PostToolUse[] | select(.matcher=="AskUserQuestion")] | length' "$tmp_pre/.claude/settings.json")
[[ "$n_aq" == "1" ]] || fail "AskUserQuestion hook appears $n_aq times after double-install (merge not idempotent)"
# Order preservation: the user's pre-existing Edit hook was registered FIRST,
# the merge appended AskUserQuestion. A jq `unique` (which sorts) would
# silently re-order them alphabetically (Ask… < Edit). The user-defined
# execution order must survive intact.
post0_matcher=$(jq -r '.hooks.PostToolUse[0].matcher' "$tmp_pre/.claude/settings.json")
[[ "$post0_matcher" == "Edit" ]] || fail "settings merge re-ordered PostToolUse hooks: index 0 is '$post0_matcher', expected 'Edit' (the user's pre-existing entry)"
rm -rf "$tmp_pre"
pass "settings merge preserves unrelated hooks + top-level keys, stays idempotent, and preserves user-defined hook order"

# 3e. Migration prune: the roborev PreToolUse[Bash] bridge moved to seed-auto-roborev,
#     so the fragment carries it again. A machine seeded by seed-auto-roborev
#     keeps stale `~/.config/roborev/claude-hooks/*` PreToolUse entries pointing
#     into a retired seed — dead on every Bash command, and doubling every gate
#     if left beside the repo-owned ones. Re-running install must prune exactly
#     those while leaving the repo-owned hooks intact. Includes an XDG-relocated
#     row, since XDG_CONFIG_HOME moves them off the `/.config/` path.
#     Covers both prune branches: a matcher object where the stale command is
#     CO-LOCATED with a hook we must keep (strip only the nested command, keep
#     the matcher), and a matcher object where the stale command is ALONE (drop
#     the now-empty matcher).
tmp_mig="$(mktemp -d)"
mkdir -p "$tmp_mig/.claude"
cat > "$tmp_mig/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/roborev-pre-commit-context.py"},{"type":"command","command":"/home/u/.config/roborev/claude-hooks/roborev-pre-commit-context.py"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"/home/u/.config/roborev/claude-hooks/roborev-pre-push-gate.py"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"/home/u/xdg/roborev/claude-hooks/roborev-pre-checkout-gate.py"}]}]}}
JSON
CONFIG_SKIP_MCP=1 HOME="$tmp_mig" just install >/dev/null
jq -e 'all(.hooks.PreToolUse[]?.hooks[]?; (.command // "") | contains("/.config/roborev/claude-hooks/") | not)' "$tmp_mig/.claude/settings.json" >/dev/null \
  || fail "install did not prune the stale seed-owned roborev PreToolUse[Bash] hooks (dangling-hook migration bug)"
jq -e 'any(.hooks.PreToolUse[]?.hooks[]?; .command == "$HOME/.claude/hooks/roborev-pre-commit-context.py")' "$tmp_mig/.claude/settings.json" >/dev/null \
  || fail "install dropped the repo-owned roborev bridge co-located in the same matcher as a stale one (prune too broad)"
# The XDG-relocated row specifically: matching on /.config/ instead of the stable
# tail would leave this one behind, which is the escape the fixture exists for.
jq -e 'all(.hooks.PreToolUse[]?.hooks[]?; (.command // "") | contains("/xdg/roborev/claude-hooks/") | not)' "$tmp_mig/.claude/settings.json" >/dev/null \
  || fail "install did not prune the XDG-relocated seed hook (prune matched /.config/ rather than the stable tail)"
jq -e 'all(.hooks.PreToolUse[]?; (.hooks | length) > 0)' "$tmp_mig/.claude/settings.json" >/dev/null \
  || fail "install left an empty PreToolUse matcher object after stripping its only (stale) hook"
rm -rf "$tmp_mig"
pass "just install strips only the stale seed-owned roborev commands, preserves the repo-owned bridge"

# `install-roborev` must restore code-config's Claude-hook ownership even when
# the frozen legacy install verifies unsuccessfully. Otherwise the failure path
# leaves both copies registered and every commit/push/switch runs twice.
tmp_robo_fail="$(mktemp -d)"
seed_dir="$tmp_robo_fail/.cache/seed-auto-roborev"
mkdir -p "$seed_dir/.git" "$seed_dir/ref" "$tmp_robo_fail/bin"
cat > "$tmp_robo_fail/bin/git" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/git.log"
exit 0
SH
chmod +x "$tmp_robo_fail/bin/git"
cat > "$seed_dir/ref/install.sh" <<'SH'
#!/bin/sh
mkdir -p "$HOME/.claude"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'$HOME'/.config/roborev/claude-hooks/roborev-pre-push-gate.py"}]}]}}' > "$HOME/.claude/settings.json"
SH
cat > "$seed_dir/ref/verify.sh" <<'SH'
#!/bin/sh
exit 23
SH
if CONFIG_SKIP_MCP=1 CONFIG_SKIP_PLUGINS=1 HOME="$tmp_robo_fail" PATH="$tmp_robo_fail/bin:$PATH" just install-roborev >/dev/null 2>&1; then
  fail "install-roborev hid the legacy verifier failure"
fi
grep -qF "checkout --detach --quiet 83db20dcc8cb60b1eff73e06892b3140ec33b3d8" "$tmp_robo_fail/git.log" \
  || fail "install-roborev did not check out the reviewed legacy seed commit"
jq -e 'all(.hooks.PreToolUse[]?.hooks[]?; (.command // "") | contains("/roborev/claude-hooks/") | not)' "$tmp_robo_fail/.claude/settings.json" >/dev/null \
  || fail "failed install-roborev left legacy Claude hooks registered"
jq -e 'any(.hooks.PreToolUse[]?.hooks[]?; .command == "$HOME/.claude/hooks/roborev-pre-push-gate.py")' "$tmp_robo_fail/.claude/settings.json" >/dev/null \
  || fail "failed install-roborev did not restore code-config's Claude hooks"
rm -rf "$tmp_robo_fail"
pass "install-roborev restores code-config Claude hooks even when legacy verification fails"

# 3f. Delete-aware: `just install` prunes a repo-owned skill or doc symlink whose
#     source was removed from code-config (the regression that left dangling
#     ~/.claude/skills/<name> and ~/.claude/<name>.md links on installed hosts
#     after a deletion), while leaving user-owned symlinks (pointing outside the
#     repo) intact.
tmp_prune="$(mktemp -d)"
HOME="$tmp_prune" just install >/dev/null
# Stale repo-owned links: targets under $REPO that no longer exist.
ln -sfn "$PWD/claude/skills/__smoke-removed-skill__" "$tmp_prune/.claude/skills/__smoke-removed-skill__"
ln -sfn "$PWD/claude/__smoke-removed-doc__.md" "$tmp_prune/.claude/__smoke-removed-doc__.md"
# User-owned links: point outside the repo, must survive the prune.
mkdir -p "$tmp_prune/external-skill"; echo "x" > "$tmp_prune/external-skill/SKILL.md"
ln -sfn "$tmp_prune/external-skill" "$tmp_prune/.claude/skills/__smoke-user-skill__"
echo "x" > "$tmp_prune/external-doc.md"
ln -sfn "$tmp_prune/external-doc.md" "$tmp_prune/.claude/__smoke-user-doc__.md"
HOME="$tmp_prune" just install >/dev/null
[[ ! -L "$tmp_prune/.claude/skills/__smoke-removed-skill__" ]] || fail "stale repo-owned skill symlink not pruned by delete-aware install"
[[ ! -L "$tmp_prune/.claude/__smoke-removed-doc__.md" ]] || fail "stale repo-owned doc symlink not pruned by delete-aware install"
[[ -L "$tmp_prune/.claude/skills/__smoke-user-skill__" ]] || fail "user-owned skill symlink (outside repo) wrongly pruned"
[[ -L "$tmp_prune/.claude/__smoke-user-doc__.md" ]] || fail "user-owned doc symlink (outside repo) wrongly pruned"
real_skill=$(basename "${skills[0]%/}")
[[ -L "$tmp_prune/.claude/skills/$real_skill" ]] || fail "real repo skill $real_skill missing after prune pass (prune over-reached)"
[[ -L "$tmp_prune/.claude/$(basename "${docs[0]}")" ]] || fail "real repo doc $(basename "${docs[0]}") missing after prune pass (prune over-reached)"
rm -rf "$tmp_prune"
pass "just install prunes removed repo-owned skill and doc symlinks, preserves user-owned ones"

# 4. `just install` backs up both a legacy real skill dir AND a legacy real
#    doc file. Skill is seeded at the LAST position so a pass proves the
#    recipe handles a legacy dir at any position, not just index 0.
tmp2="$(mktemp -d)"
trap 'rm -rf "$tmp" "$tmp2"' EXIT
n=${#skills[@]}
last_skill=$(basename "${skills[$((n-1))]%/}")
first_doc=$(basename "${docs[0]}")
mkdir -p "$tmp2/.claude/skills/$last_skill"
touch "$tmp2/.claude/skills/$last_skill/.legacy"
echo "real-doc-content" > "$tmp2/.claude/$first_doc"
echo "real-tmux-content" > "$tmp2/.tmux.conf"   # legacy real ~/.tmux.conf must be backed up, not clobbered

HOME="$tmp2" just install >/dev/null
[[ -L "$tmp2/.claude/skills/$last_skill" ]] || fail "legacy skill $last_skill wasn't replaced with symlink"
[[ -L "$tmp2/.claude/$first_doc" ]] || fail "legacy doc $first_doc wasn't replaced with symlink"
[[ -L "$tmp2/.tmux.conf" && "$(readlink "$tmp2/.tmux.conf")" == "$PWD/tmux.conf" ]] || fail "legacy ~/.tmux.conf wasn't replaced with a symlink to the repo's tmux.conf"
backup_dir=$(ls -d "$tmp2/.claude/backups/pre-symlink-"*/ 2>/dev/null | head -1)
[[ -n "$backup_dir" ]] || fail "no backup dir created when legacy targets present"
[[ -d "${backup_dir}skill-$last_skill" && -f "${backup_dir}skill-$last_skill/.legacy" ]] || fail "legacy skill content not preserved at ${backup_dir}skill-$last_skill/"
[[ -f "${backup_dir}$first_doc" ]] || fail "legacy doc not preserved at ${backup_dir}$first_doc"
[[ "$(cat "${backup_dir}$first_doc")" == "real-doc-content" ]] || fail "backed-up doc content corrupted"
[[ "$(cat "${backup_dir}.tmux.conf" 2>/dev/null)" == "real-tmux-content" ]] || fail "legacy ~/.tmux.conf not preserved at ${backup_dir}.tmux.conf"
pass "just install backs up legacy real skill dirs, doc files, and ~/.tmux.conf into the timestamped backup dir"

# 5. Refuse when any install-root path is a symlink. Three variants exercise
#    the bug class:
#      - skills-live: ~/.claude/skills -> live dir
#      - skills-dangling: ~/.claude/skills -> nonexistent (load-bearing: must
#        beat mkdir -p, otherwise surfaces as "mkdir: File exists" rather than
#        the recipe's refusal)
#      - claude-symlink: ~/.claude itself -> live dir (would otherwise route
#        the doc loop through the parent symlink and back source docs out of
#        claude/)
tmp3="$(mktemp -d)"
trap 'rm -rf "$tmp" "$tmp2" "$tmp3"' EXIT
for variant in skills-live skills-dangling claude-symlink; do
  rm -rf "$tmp3"/* "$tmp3"/.[!.]*
  case "$variant" in
    skills-live)
      mkdir -p "$tmp3/.claude" "$tmp3/elsewhere"
      ln -s "$tmp3/elsewhere" "$tmp3/.claude/skills"
      ;;
    skills-dangling)
      mkdir -p "$tmp3/.claude"
      ln -s "$tmp3/this-does-not-exist" "$tmp3/.claude/skills"
      ;;
    claude-symlink)
      mkdir -p "$tmp3/elsewhere"
      ln -s "$tmp3/elsewhere" "$tmp3/.claude"
      ;;
  esac

  set +e
  HOME="$tmp3" just install >"$tmp3/out.log" 2>"$tmp3/err.log"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "just install should refuse install-root symlink ($variant)"
  grep -q "is a symlink" "$tmp3/err.log" || fail "just install didn't print the symlink-refuse error ($variant)"
done
pass "just install refuses install-root symlinks (skills-live, skills-dangling, claude-symlink)"

# 6. The merge policy lives in PR_LIFECYCLE.md + babysit-pr SKILL.md; this is just
#    a regression grep for the one mechanical tell — a copy-paste-runnable bare
#    `gh pr merge` at line-start (a command block an agent could run unconditionally).
#    Backtick-quoted prose mentions of the gated, authorized merge are fine.
merge_hits=$(grep -nE '^[[:space:]]*gh pr merge\b' claude/skills/babysit-pr/SKILL.md || true)
[[ -z "$merge_hits" ]] || fail "babysit-pr/SKILL.md has a line-start 'gh pr merge' command block (the merge must stay in gated prose, never a copy-paste-runnable line): $merge_hits"
pass "babysit-pr/SKILL.md does not invoke immediate 'gh pr merge'"

# 6b. babysit-pr posts comments via REST (core rate-limit bucket), not `gh pr
#     comment` (GraphQL bucket) — GraphQL exhausts independently on long loops.
#     Two regressions to catch:
#       - command lines at line-start (executable recipes drifting back)
#       - Step 6 surface-mapping prose ("PR-level comments → top-level ...")
#         drifting back to name `gh pr comment` — agents read prose too.
comment_hits=$(grep -nE '^[[:space:]]*gh pr comment\b' claude/skills/babysit-pr/SKILL.md || true)
[[ -z "$comment_hits" ]] || fail "babysit-pr/SKILL.md invokes 'gh pr comment' (use REST 'gh api repos/<o>/<r>/issues/<#>/comments --input -' instead): $comment_hits"
prose_hits=$(grep -nE 'PR-level comments .* → .*`gh pr comment`' claude/skills/babysit-pr/SKILL.md || true)
[[ -z "$prose_hits" ]] || fail "babysit-pr/SKILL.md surface-mapping prose routes PR-level comments to 'gh pr comment' (should name REST '/issues/<#>/comments'): $prose_hits"
pass "babysit-pr/SKILL.md posts comments via REST, not 'gh pr comment' (commands + prose)"

# 6c. babysit-pr resolves main→PR merge conflicts in-loop, not by exiting.
#     The recipe lives in PR_LIFECYCLE.md § "Merge conflicts (resolve
#     autonomously)"; the SKILL's "Stop the loop early" delegates there. Fence
#     against the prior absolute-exit shape regressing back.
rebase_hits=$(grep -nE 'Rebase needed|leaving for human' claude/skills/babysit-pr/SKILL.md || true)
[[ -z "$rebase_hits" ]] || fail "babysit-pr/SKILL.md says to exit on rebase / 'leaving for human' (conflicts are now in-loop per PR_LIFECYCLE.md): $rebase_hits"
grep -q '## Merge conflicts (resolve autonomously)' claude/PR_LIFECYCLE.md || fail "PR_LIFECYCLE.md missing the '## Merge conflicts (resolve autonomously)' section"
# Both halves on ONE line: a baseRefName binding in another section would satisfy
# two independent greps. No numbered-list anchor — pinning markdown shape is what
# made the previous assertion brittle enough to go red on a semantic no-op. The
# QUOTES are pinned deliberately though: "origin/$BASE" is the injection fence for
# a PR-controlled ref, not formatting — don't loosen them out of the pattern.
grep -qE 'baseRefName.*git merge "origin/\$BASE"' claude/PR_LIFECYCLE.md || fail "PR_LIFECYCLE.md conflict recipe must resolve the PR's base (baseRefName) and merge the quoted \"origin/\$BASE\" on the same step"
pass "babysit-pr resolves merge conflicts in-loop (recipe in PR_LIFECYCLE.md, SKILL.md doesn't exit)"

# 7. babysit-pr's Step 7 Monitor is the zero-GitHub-API container-log wake, gated
#    by a fail-loud SSH check on wakeup. knightwatch now runs containerized and
#    may run multiple reviewer containers; the Monitor discovers the compose
#    project by image and tails its aggregated logs. Load-bearing properties that
#    must not silently regress:
#      - no `gh` calls — a poll back inside the Monitor would recreate the
#        secondary-rate-limit burn the container-log wake eliminates
#      - `docker compose ... logs --tail 0 -f` — `--tail 0` follows from the
#        logs' end (the journalctl `-n 0` analog); dropping it replays old rows
#        and a stale `Done with` fires a spurious wake
#      - discovery by image (`--filter ancestor=knightwatch-reviewer:dev`) — no
#        hardcoded deploy-dir / compose-project name, so adding a reviewer
#        account or moving the checkout doesn't silently blind the Monitor
#      - `-p "$PROJ"` addressing (not `-f "$CF"`) — the project's
#        `config_files` label is comma-joined under a multi-file project, so a
#        single `-f` chokes and the tail busy-loops on instant re-check
#      - inner `timeout 1740` (strictly below the 1800s harness cap) — an equal
#        timeout races the harness, which can kill the tail before the re-check
#        content line emits, surfacing a bare "Monitor timed out"
#      - the `## In-loop maintenance` active/spent discriminator (`currently-armed`)
#        — without it the post-approval keep-alive loop treats its own re-check
#        tick as a spent no-op and stalls forever
#      - Step 7 SSH-gates re-arming with `ssh ... "$KWR_USER@wakeup" true`; a missing
#        gate silently falls back to looping against a down host
#      - the SSH gate is preceded by a `hostname == wakeup` branch that
#        short-circuits to REACHABLE=1 — routing the on-wakeup case back
#        through SSH-to-self fails publickey-denied and exits no-schedule
#        spuriously (regression PR #37 fixed)
#      - the Monitor command body itself branches on `hostname == wakeup` so
#        it picks a local vs SSH-wrapped tail — dropping the branch sends
#        on-wakeup arms through SSH-to-self
#      - one-shot Monitor — `persistent=True`/`while true`/`sleep 300` would
#        restore the degraded 5-min poll loop that was removed
monitor_block=$(awk '/^Monitor\(/,/^\)$/' claude/skills/babysit-pr/SKILL.md)
[[ -n "$monitor_block" ]] || fail "could not locate the babysit-pr Monitor( ... ) block in SKILL.md"
gh_hits=$(grep -nE '\bgh ' <<<"$monitor_block" || true)
[[ -z "$gh_hits" ]] || fail "babysit-pr Monitor block invokes 'gh' (it must make zero GitHub API calls): $gh_hits"
grep -qF 'logs --tail 0 -f' <<<"$monitor_block" \
  || fail "babysit-pr Monitor must tail the reviewer's compose-project container logs with 'docker compose ... logs --tail 0 -f' (--tail 0 prevents stale-completion wakes — the journalctl -n 0 analog now that knightwatch is containerized)"
grep -qF 'ancestor=knightwatch-reviewer:dev' <<<"$monitor_block" \
  || fail "babysit-pr Monitor must discover the reviewer compose project by image ('--filter ancestor=knightwatch-reviewer:dev'), not a hardcoded deploy-dir / project name (knightwatch may run multiple reviewer containers)"
grep -qF 'compose -p "$PROJ" logs' <<<"$monitor_block" \
  || fail "babysit-pr Monitor must address the reviewer project by name ('docker compose -p \"\$PROJ\" logs') — the 'com.docker.compose.project.config_files' label is comma-joined under a multi-file project, so a single '-f' chokes and the tail instant-exits into a busy re-check loop"
for antipattern in 'config_files' '-f "$CF"'; do
  grep -qF -e "$antipattern" <<<"$monitor_block" \
    && fail "babysit-pr Monitor block must not address the project via '$antipattern' (comma-joined label breaks a single '-f' → busy-loop); use '-p \"\$PROJ\"' instead"
done
grep -qF 'timeout 1740' <<<"$monitor_block" \
  || fail "babysit-pr Monitor must size its inner 'timeout' strictly below the harness timeout_ms (1740s < 1800s) so the '|| echo re-check' content line always emits before the harness can preempt with a bare 'Monitor timed out'"
grep -qF 'timeout 1800' <<<"$monitor_block" \
  && fail "babysit-pr Monitor inner timeout must be 1740 (strictly below the 1800s harness cap), not 1800 — an equal timeout is a race the harness can win, killing the tail before the re-check line emits"
grep -qF '"$(hostname)" == "wakeup"' <<<"$monitor_block" \
  || fail "babysit-pr Monitor block must branch on '\"\$(hostname)\" == \"wakeup\"' to pick a local vs SSH-wrapped tail (regression PR #37 fixed)"
grep -qF 'ssh -o ConnectTimeout=10 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 "$KWR_USER@wakeup"' <<<"$monitor_block" \
  || fail "babysit-pr Monitor block must still contain the SSH-wrapped tail branch for off-wakeup runs"
grep -qF 'ssh -o ConnectTimeout=5 -o BatchMode=yes "$KWR_USER@wakeup" true' claude/skills/babysit-pr/SKILL.md \
  || fail "babysit-pr Step 7 must SSH-check wakeup with 'ssh -o ConnectTimeout=5 -o BatchMode=yes \"\$KWR_USER@wakeup\" true' before arming the Monitor (fail-loud gate on unreachable host)"
hostname_line=$(grep -nF '"$(hostname)" == "wakeup"' claude/skills/babysit-pr/SKILL.md | head -1 | cut -d: -f1)
ssh_gate_line=$(grep -nF 'ssh -o ConnectTimeout=5 -o BatchMode=yes "$KWR_USER@wakeup" true' claude/skills/babysit-pr/SKILL.md | head -1 | cut -d: -f1)
[[ -n "$hostname_line" && -n "$ssh_gate_line" && "$hostname_line" -lt "$ssh_gate_line" ]] \
  || fail "babysit-pr Step 7 must check 'hostname == wakeup' BEFORE the SSH probe; routing the on-wakeup case back through SSH-to-self exits no-schedule spuriously (regression PR #37 fixed)"
for pattern in 'persistent=True' 'while true' 'sleep 300'; do
  grep -qF "$pattern" <<<"$monitor_block" \
    && fail "babysit-pr Monitor block must not contain '$pattern' (the degraded 5-min poll loop was removed)"
done
fallback_hits=$(grep -nE 'ScheduleWakeup\(delaySeconds=600|\*\*Fallback\*\*' claude/skills/babysit-pr/SKILL.md || true)
[[ -z "$fallback_hits" ]] || fail "babysit-pr/SKILL.md reintroduced the deleted 600s ScheduleWakeup / **Fallback** poll branch: $fallback_hits"
# Whole-section check (not a $monitor_block check): the active/spent timeout discriminator
# lives in the '## In-loop maintenance' prose, not the Monitor( ) block — extract that section.
inloop_block=$(awk '/^## In-loop maintenance$/{f=1;next} /^## /{f=0} f' claude/skills/babysit-pr/SKILL.md)
grep -qF 'currently-armed' <<<"$inloop_block" \
  || fail "babysit-pr '## In-loop maintenance' must keep the active/spent discriminator: a timeout for the *currently-armed* task ID (no prior wake) IS the re-check tick (re-enter), not a spent-monitor no-op — without it the post-approval keep-alive loop stalls forever"
pass "babysit-pr Monitor command: no 'gh' calls, tails container logs with --tail 0, image-discovered, -p-addressed (no comma-joined -f busy-loop), 1740s inner timeout (sub-harness), SSH-gated, hostname-branched, one-shot, no 600s fallback; In-loop active/spent discriminator pinned"

# 8. cleanup mechanics — extracted to skills/cleanup/scripts/ (friction-first
# redesign: SKILL.md holds the judgment, the scripts hold the deterministic
# bash, executed from the installed clone — the $SVC trust anchor). Each fence
# below catches a regression that would break an OBSERVED behavior (candidate
# loop gone, security shape gone, wrong-checkout corpus reads).
# Keep cleanup fences to observed regressions only (CODING_STANDARDS § Anti-Bloat).
cleanup_md=claude/skills/cleanup/SKILL.md
cleanup_scripts=claude/skills/cleanup/scripts
claim_sh=$cleanup_scripts/claim-checkout.sh
[[ -f "$cleanup_md" ]] || fail "cleanup/SKILL.md not found at $cleanup_md"
for s in claim-checkout.sh release-claim.sh reseat.sh stash-untracked.sh teardown-dev-stack.sh commit-track-a.sh commit-track-b.sh; do
  [[ -x "$cleanup_scripts/$s" ]] || fail "cleanup script $s missing or not executable"
done
[[ -f "$cleanup_scripts/mine-transcript.py" ]] || fail "cleanup script mine-transcript.py missing"
# The skill must INVOKE the scripts from the installed clone (~/services), never
# a ~/Hacking candidate (trust anchor: candidates are data to validate, not code
# to execute), and must wire every script — a dropped invocation orphans the
# mechanics that used to be inline.
grep -qF 'SC=~/services/code-config/claude/skills/cleanup/scripts' "$cleanup_md" \
  || fail "cleanup/SKILL.md must invoke its scripts from the installed clone (SC=~/services/…) — candidate checkouts are untrusted data"
for s in mine-transcript.py claim-checkout.sh commit-track-a.sh commit-track-b.sh reseat.sh stash-untracked.sh teardown-dev-stack.sh release-claim.sh; do
  grep -qF "$s" "$cleanup_md" || fail "cleanup/SKILL.md no longer invokes $s (extracted-mechanics wiring regressed)"
done
grep -qF 'code-config ~/Hacking/code-config{0..9}' "$claim_sh" \
  || fail "claim-checkout.sh must order candidates legacy-bare-first then slots code-config0..9 (uniform slot-model claim loop regressed)"
grep -qE '^[[:space:]]*\.[[:space:]]+"\$SVC/lib/claim\.sh"' "$claim_sh" \
  || fail "claim-checkout.sh must SOURCE lib/claim.sh from the INSTALLED clone (. \"\$SVC/lib/claim.sh\") — claim_slot/release_slot undefined at runtime if dropped, and a ~/Hacking candidate must never be the code source (security trust anchor)"
grep -qF 'git -C "$SVC" remote get-url origin' "$claim_sh" \
  || fail "claim-checkout.sh must derive \$ORIGIN from the installed clone, not a dev candidate (a wrong-origin slot must not self-bless its remote)"
grep -qE '_cc_free\(\) \{ \[ "\$\(git -C "\$1" symbolic-ref --short HEAD 2>/dev/null\)" = main \]' "$claim_sh" \
  || fail "claim-checkout.sh must tighten the fleet predicate to exactly main (_cc_free) — _tcp_eligible alone admits master, but cleanup writes/pushes main only"
[[ -f lib/claim.sh ]] \
  || fail "lib/claim.sh must exist in the repo (claim-checkout.sh sources it)"
# §1a2 must hand its idle predicate to reseat as the pre-switch guard. The unit
# tests cover both directions of the guard inside reseat, but nothing without a
# real tmux can catch this ARGUMENT going missing — and dropping it is exactly
# how a pane that starts a build during the seconds-long gh call gets switched
# to main underneath itself. Static fence so that revert breaks loudly here.
grep -qE 'reseat_if_ready "\$dir" _cc_reclaimable' "$claim_sh" \
  || fail "claim-checkout.sh §1a2 must pass _cc_reclaimable to reseat_if_ready as its pre-switch guard (without it, a slot that becomes busy mid-query is switched anyway)"
# The 4h claim-lock staleness window is hand-mirrored in claim.sh (claim_slot's
# stale-steal) and pick.sh (_tcp's lock-aware skip) — they can't share code since
# pick.sh ships inline over ssh. Fence the constant so drift breaks loudly here
# instead of as a silent pick/claim disagreement (a slot _tcp offers but claim_slot
# then refuses to steal).
{ grep -q 'mmin +240' lib/claim.sh && grep -q 'mmin +240' lib/pick.sh; } \
  || fail "the claim-lock staleness window ('-mmin +240') must match in BOTH lib/claim.sh and lib/pick.sh"
# Locks come from the shared claim_lock_path helper (not a hand-built path), so
# the namespace can't drift from tc/pick. Fence BOTH sides: the script must
# ASSIGN locks from the helper, and claim.sh must DEFINE it.
grep -qE '=\$\(claim_lock_path ' "$claim_sh" \
  || fail "claim-checkout.sh must assign locks via \$(claim_lock_path …), not a hand-built path"
if grep -qE '^[[:space:]]*[a-z_]+=\$\{?TC_LOCK_DIR' "$claim_sh"; then
  fail "claim-checkout.sh hand-builds a lock path from \$TC_LOCK_DIR — use claim_lock_path instead (catches a partial revert)"
fi
grep -q 'claim_lock_path()' lib/claim.sh \
  || fail "lib/claim.sh must define claim_lock_path() (tc claim + /cleanup call it)"
grep -qE 'claim_slot "\$lock"' "$claim_sh" \
  || fail "claim-checkout.sh must auto-claim a candidate via claim_slot sentinel (cleanup has a standing no-prompt checkout-selection contract per CLAUDE.md § Workspace Isolation)"
grep -qE 'release_slot "\$\{?CLAIM_LOCK' "$cleanup_scripts/release-claim.sh" \
  || fail "release-claim.sh must release the sentinel claim (\$CLAIM_LOCK) — otherwise a crashed run blocks the slot until the 4h staleness rule kicks in"
grep -qF '= "$ORIGIN" ]' "$claim_sh" \
  || fail "claim-checkout.sh must require candidate origin to match the reference clone's \$ORIGIN (security: don't claim an unrelated-repo clone)"
# `git stash` at line-start = executable invocation (CLAUDE.md § Git Safety:
# never discard uncommitted work) — in the skill OR any of its scripts.
stash_hits=$(grep -nE '^[[:space:]]*git stash\b' "$cleanup_md" "$cleanup_scripts"/*.sh || true)
[[ -z "$stash_hits" ]] || fail "cleanup skill/scripts invoke 'git stash' (CLAUDE.md § Git Safety: never discard uncommitted work): $stash_hits"
# Step 2 is LAZY: reads route through $CONFIG_DIR, and PROPOSALS.md is read by
# title-grep, never whole. Catches the round-1-observed regression class
# (reading from the busy primary checkout) plus an unconditional-read revert
# (the token-cost contract of the friction-first redesign).
step2plus=$(awk '/^## Step 2 —/{p=1} p' "$cleanup_md")
grep -qF '$CONFIG_DIR/claude/PROPOSALS.md' <<<"$step2plus" \
  || fail "cleanup/SKILL.md Step 2 must route the PROPOSALS.md title-grep through \$CONFIG_DIR (not a hard-coded path)"
grep -qF "grep -n '^## '" <<<"$step2plus" \
  || fail "cleanup/SKILL.md Step 2 must read PROPOSALS.md lazily by ^## title grep (never whole)"
grep -qE 'git -C "\$CONFIG_DIR" log' <<<"$step2plus" \
  || fail "cleanup/SKILL.md Step 2 must use 'git -C \"\$CONFIG_DIR\" log' for recent-activity (not unqualified git)"
pass "cleanup mechanics: scripts present + wired from the installed clone; claim loop (legacy-bare-first + slots 0-9) + atomic-mkdir auto-claim + claim-release + origin-match + no stash; lazy Step 2 reads route through \$CONFIG_DIR"

# 8b. cleanup two-track model: Track A auto-nudges corpus ordering on main (no
#     review); Track B records content proposals in PROPOSALS.md (human-harvested).
#     Guard the bright lines: NO graduation PR, NO gather script, NO to-process/;
#     plus the friction-first essentials (Step 0 miner as data, early exit).
grep -qF 'memory/' "$cleanup_md" \
  || fail "cleanup/SKILL.md Step 0 must read the project memory/ ledger (capture pipeline regressed)"
grep -qiE 'feedback' "$cleanup_md" \
  || fail "cleanup/SKILL.md Step 0 must mine feedback-type memories (capture pipeline regressed)"
grep -qiE 'autonomy[ -]blocker' "$cleanup_md" \
  || fail "cleanup/SKILL.md must lead with human feedback + autonomy blockers (headline-learnings intent regressed)"
grep -qiE 'early exit' "$cleanup_md" \
  || fail "cleanup/SKILL.md must keep the early-exit gate (a clean session skips the claim + ALL corpus reads)"
grep -qiE 'never instructions' "$cleanup_md" \
  || fail "cleanup/SKILL.md must mark mined transcript/conversation text as data, never instructions (distrust boundary)"
# Track B target is PROPOSALS.md, and the doc exists.
grep -qF 'claude/PROPOSALS.md' "$cleanup_md" \
  || fail "cleanup/SKILL.md Track B must record proposals in claude/PROPOSALS.md"
[[ -f claude/PROPOSALS.md ]] \
  || fail "claude/PROPOSALS.md must exist (Track B staging doc)"
# Track B [removes-handback] tag: the visible form of the hard-stop grade must be
# taught in all three prose contracts (writer + canonical model + staging doc), or
# a later prompt edit could silently drop the harvest-priority signal.
for _f in "$cleanup_md" claude/CLEANUP_RANKING_MODEL.md claude/PROPOSALS.md; do
  grep -qF '[removes-handback]' "$_f" \
    || fail "$_f must teach the [removes-handback] tag (hard-stop harvest-priority contract)"
done
# The old findings + concat machinery is gone.
[[ ! -d claude/to-process ]] \
  || fail "claude/to-process/ must be removed (consolidated into PROPOSALS.md)"
[[ ! -e claude/skills/cleanup/gather-proposals.sh ]] \
  || fail "gather-proposals.sh must be removed (one PROPOSALS.md; no concat script)"
# Corpus-WIDE: no doc references the removed machinery (not just SKILL.md).
for _tok in 'to-process/' 'feat/promote-' 'gather-proposals'; do
  _hits=$(grep -rlF "$_tok" code-config README.md 2>/dev/null || true)
  [[ -z "$_hits" ]] || fail "stale '$_tok' still in corpus (old cleanup machinery removed): $_hits"
done
# Track A: a move-up-one nudge op, committed to main, secret-scanned PROPOSALS.md.
grep -qiE 'nudge' "$cleanup_md" \
  || fail "cleanup/SKILL.md Track A must describe the nudge (move-up-one) op"
{ grep -qF 'push origin main' "$cleanup_scripts/commit-track-a.sh" && grep -qF 'push origin main' "$cleanup_scripts/commit-track-b.sh"; } \
  || fail "commit-track-a.sh + commit-track-b.sh must commit/push directly to main (both tracks)"
grep -qE '\$HERE/\.\./\.\./\.\./hooks/secret-scan\.py" --scan-file' "$cleanup_scripts/commit-track-b.sh" \
  || fail "commit-track-b.sh must run the INSTALLED clone's secret-scan.py (script-relative \$HERE path, never \$CONFIG_DIR's copy — a candidate checkout is data, not code) via --scan-file before the direct-main commit"
# Track C (Step 3.8): a "!" operator turn is a handback break, so it routes to
# Track C rather than the backlog (§ Step 3.8's gate owns whether that run ends in
# a PR or a reported deferral). The PR is a judgment step, so `gh pr create`
# belongs in SKILL.md and NEVER in the deterministic scripts; `gh pr merge` stays
# forbidden everywhere, because converged — not merged — is Track C's terminal state.
grep -qE '^[[:space:]]*gh pr create' "$cleanup_scripts"/*.sh \
  && fail "cleanup SCRIPTS must not invoke 'gh pr create' (Track C's PR is a SKILL.md judgment step, not deterministic mechanics)" || true
grep -qE '^[[:space:]]*gh pr merge' "$cleanup_md" "$cleanup_scripts"/*.sh \
  && fail "cleanup must never invoke 'gh pr merge' — Track C converges a PR; the merge is the human's exact-PR consent" || true
grep -qF 'Step 3.8' "$cleanup_md" \
  || fail "cleanup/SKILL.md must carry Step 3.8 (Track C: '!' handback breaks → one corpus PR)"
grep -qF 'fleet-exclamations' "$cleanup_md" \
  || fail "Track C must check recurrence via 'mine-transcript.py --fleet-exclamations' (a repeated '!' means the rule is present and unread, so the remedy is its SHAPE, not another copy)"
# Track A drop-on-conflict: the scoped reset --hard exception must be present + documented.
grep -qF 'reset --hard origin/main' "$cleanup_scripts/commit-track-a.sh" \
  || fail "commit-track-a.sh conflict path must use 'git reset --hard origin/main' to drop this run's nudges"
grep -qiE 'scoped|exception' "$cleanup_scripts/commit-track-a.sh" \
  || fail "commit-track-a.sh must document the reset --hard as a scoped § Git Safety exception"
# Track B conflict surfaces (never a silent drop), and exit 0 gates the promoted-memory mark.
grep -qF 'recover with' "$cleanup_scripts/commit-track-b.sh" \
  || fail "commit-track-b.sh must SURFACE a push that can't land with a printed recovery command (a proposal is never silently dropped)"
pass "cleanup/SKILL.md: friction-first three-track (Step 0 miner as data + early exit; Track A nudges on main, no review; Track B → PROPOSALS.md, human-harvest; Track C → one babysat corpus PR for '!' handback breaks, never merged); no gather/to-process; secret-scan + scoped reset-on-conflict in scripts"

# 8c. cleanup Step 6a — the /tmp-stash + reseat escape hatch for untracked-only
#     dirty caller checkouts. The judgment-side guards live in SKILL.md (scope,
#     gate, standing authorization, report clause); the code-side guards live in
#     stash-untracked.sh (preflight order, single TOCTOU-free snapshot, plain mv,
#     mode-700 stash, reseat re-call — NOT raw `checkout -f main`, which would
#     bypass the merged-HEAD gate and lose an unmerged feature branch's HEAD).
grep -qF '### 6a. Stash-and-reseat escape hatch' "$cleanup_md" \
  || fail "cleanup/SKILL.md must have Step 6a (stash-and-reseat escape hatch for untracked-only dirty)"
step6a_block=$(awk '/### 6a/{p=1} /^### / && !/### 6a/{if(p>0) p=0} p' "$cleanup_md")
grep -qF "caller's checkout in Step 6" <<<"$step6a_block" \
  || fail "cleanup/SKILL.md Step 6a must scope to the caller's checkout only (NOT \$CONFIG_DIR / NOT Step 1's candidate loop)"
grep -qF 'untracked-only' <<<"$step6a_block" \
  || fail "cleanup/SKILL.md Step 6a must gate on untracked-only — modified-tracked content is real work"
grep -qE 'No \`AskUserQuestion\`|standing authorization' <<<"$step6a_block" \
  || fail "cleanup/SKILL.md Step 6a must declare the no-prompt contract (standing authorization + \$STASH disclosure replaces per-instance AskUserQuestion)"
grep -qE 'untracked-stashed to' "$cleanup_md" \
  || fail "cleanup/SKILL.md readiness report must include the 'untracked-stashed to <path>' clause"
stash_sh=$cleanup_scripts/stash-untracked.sh
grep -qE 'mktemp -d|mkdir -m 700' "$stash_sh" \
  || fail "stash-untracked.sh must create a mode-700 stash dir (token-bearing env files are stashable)"
# Preflight position check: the non-`??` abort must come BEFORE the stash-dir
# creation — mixed dirty must abort untouched.
preflight_line=$(grep -nF '"${entry:0:2}" = "??"' "$stash_sh" | head -1 | cut -d: -f1)
mktemp_line=$(grep -nF 'STASH=$(mktemp -d' "$stash_sh" | head -1 | cut -d: -f1)
[[ -n "$preflight_line" && -n "$mktemp_line" && "$preflight_line" -lt "$mktemp_line" ]] \
  || fail "stash-untracked.sh must run a non-?? preflight BEFORE 'mktemp -d' (mixed dirty must abort untouched)"
grep -qE 'Step 6a aborted|non-untracked dirty' "$stash_sh" \
  || fail "stash-untracked.sh preflight must abort loudly on a non-?? entry (the untracked-only contract is the gate)"
# Per § Secrets: filenames can be token-bearing, so don't echo full paths.
grep -qF 'mv -v "$DIR' "$stash_sh" \
  && fail "stash-untracked.sh must use plain 'mv' not 'mv -v' (filenames may carry secrets — § Secrets)" || true
# Single status snapshot: TOCTOU race if preflight + move loop both read
# `git status -z --porcelain` separately. Assert exactly one such call.
status_calls=$(grep -cF 'git -C "$DIR" status -z --porcelain' "$stash_sh" || true)
[[ "$status_calls" -eq 1 ]] \
  || fail "stash-untracked.sh must run 'git status -z --porcelain' exactly once (TOCTOU: collect paths into an array during preflight, reuse for the move loop). Found $status_calls calls."
# Stash path must be surfaced BEFORE the first `mv` so a partial-failure
# recovery path is always visible.
stash_echo_line=$(grep -nE 'echo "Step 6a stash:' "$stash_sh" | head -1 | cut -d: -f1)
mv_line=$(grep -nE '^[[:space:]]*mv "\$DIR' "$stash_sh" | head -1 | cut -d: -f1)
[[ -n "$stash_echo_line" && -n "$mv_line" && "$stash_echo_line" -lt "$mv_line" ]] \
  || fail "stash-untracked.sh must echo the stash path BEFORE the first 'mv' (so a mid-loop pipefail abort still shows the recovery path)"
grep -qF 'reseat_if_ready "$DIR"' "$stash_sh" \
  || fail "stash-untracked.sh must re-call reseat_if_ready after the stash (NOT raw 'checkout -f main' — that bypasses the merged-HEAD gate)"
pass "cleanup Step 6a guards (caller-only scope, untracked-only gate, no per-instance AskUserQuestion / standing-auth contract, mode-700 stash dir, reseat_if_ready re-call, stash-path report)"

# 8d. cleanup § 6b dev-stack teardown — ownership guard. The bare `plow` compose
# project is shared across checkouts when PLOW_VARIANT is unset, so `down` must
# confirm the matched stack is the caller's (config_files path under $CALLER_REPO)
# before reaping it — and must never feed the comma-joined config_files label into
# `-f` (docker compose rejects the joined value as one path).
grep -qF '### 6b. Spin down a leftover dev stack' "$cleanup_md" \
  || fail "cleanup/SKILL.md must keep the § 6b dev-stack teardown section"
teardown_sh=$cleanup_scripts/teardown-dev-stack.sh
grep -qF 'com.docker.compose.project.config_files' "$teardown_sh" \
  || fail "teardown-dev-stack.sh must read the config_files label to settle stack ownership before teardown"
grep -qF '"$CALLER_REPO"/*)' "$teardown_sh" \
  || fail "teardown-dev-stack.sh must gate 'docker compose -p \"\$proj\" down' behind a \"\$CALLER_REPO\"/* ownership check (the bare-plow sibling-reap guard)"
grep -qF 'owned by another checkout' "$teardown_sh" \
  || fail "teardown-dev-stack.sh must skip+report when the matched stack is owned by a sibling checkout"
grep -qF -- '-f "$cfg"' "$teardown_sh" \
  && fail "teardown-dev-stack.sh must NOT feed the comma-joined config_files label into 'docker compose -f'" || true
pass "cleanup Step 6b teardown (config_files ownership prefix-gate before down, sibling skip+report, no -f on the comma-joined label)"

# 9. setup-playwright-mcp.sh derives the right registration flags per platform.
#    Sourcing defines the functions without running main (BASH_SOURCE guard).
#    macOS → headed; headless Linux → --headless + --executable-path pointing at
#    the resolved browser (system Chromium when present, else the bundled build
#    main() downloads and passes in). An empty path is the no-browser fallback.
#    --no-sandbox is not part of this mapping — main() adds it per-host (below).
[[ -x ./setup-playwright-mcp.sh ]] || fail "setup-playwright-mcp.sh missing or not executable"
# shellcheck disable=SC1091
source ./setup-playwright-mcp.sh
got_mac=$(derive_mcp_args Darwin "")
got_sys=$(derive_mcp_args Linux /usr/bin/chromium)
got_bundled=$(derive_mcp_args Linux /home/x/.cache/ms-playwright/chromium-1224/chrome-linux64/chrome)
got_none=$(derive_mcp_args Linux "")
# --no-sandbox is NOT in the base mapping — main() adds it per-host only when
# the sandboxed launch test fails, so the sandbox stays on where it works.
[[ "$got_mac" == "--isolated" ]] || fail "macOS should register headed (--isolated only): got '$got_mac'"
[[ "$got_sys" == "--isolated --headless --executable-path /usr/bin/chromium" ]] \
  || fail "Linux + system chromium should reuse it headless: got '$got_sys'"
[[ "$got_bundled" == "--isolated --headless --executable-path /home/x/.cache/ms-playwright/chromium-1224/chrome-linux64/chrome" ]] \
  || fail "Linux + bundled chromium must wire --executable-path too: got '$got_bundled'"
[[ "$got_none" == "--isolated --headless" ]] \
  || fail "Linux with no resolvable browser should fall back to headless only: got '$got_none'"
pass "setup-playwright-mcp.sh derives correct per-platform MCP flags (sandbox on by default)"

# 9b. main() regression guard: the pure derive_mcp_args mapping above passed even
#     against the old code, because the bug was in main()'s *wiring* — it derived
#     args from the system-only $chromium instead of the resolved (bundled)
#     test_bin, so a headless Linux host with no system Chromium registered with
#     NO --executable-path and fell back to the absent `chrome` channel. Drive the
#     real main() with that host's shape faked (no system chromium, bundled build
#     resolved) and assert the `claude mcp add` argv carries --executable-path
#     <bundled chrome>. This FAILS against the pre-fix main() and passes after.
tmp_mcp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$tmp2" "$tmp3" "$tmp_mcp"' EXIT
mkdir -p "$tmp_mcp/bin" "$tmp_mcp/pw/chrome-linux64" "$tmp_mcp/.claude"
export CLAUDE_ARGV_LOG="$tmp_mcp/argv.log"; : > "$CLAUDE_ARGV_LOG"
# fake claude: log argv (so we can assert `mcp add`); print nothing for `mcp list`
# so main's exact-match fast-path misses and it proceeds to (re-)register.
printf '#!/usr/bin/env bash\necho "$*" >> "$CLAUDE_ARGV_LOG"\n' > "$tmp_mcp/bin/claude"
# fake bundled chrome: launch_ok just needs a clean exit for the sandboxed probe.
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp_mcp/pw/chrome-linux64/chrome"
chmod +x "$tmp_mcp/bin/claude" "$tmp_mcp/pw/chrome-linux64/chrome"
# Fake just this host's external surface — no real download, no real browser:
find_claude() { echo "$tmp_mcp/bin/claude"; }
uname() { echo Linux; }                                         # force the Linux branch on any host
# Deny any browser channel (not just the two probed today) so the "no system
# browser" shape holds regardless of what the runner has installed; delegate
# everything else (jq etc.) to the real builtin.
command() { if [[ "$1" == -v ]]; then case "$2" in chromium|chromium-browser|google-chrome|google-chrome-stable|chrome|chrome-browser) return 1;; esac; fi; builtin command "$@"; }
# Narrow stubs to the exact calls main() makes — an unexpected npm/npx invocation
# fails loudly (set -e) instead of being silently absorbed by a catch-all.
npm() { case "$*" in view*dependencies.playwright) echo "1.61.0";; *) echo "unexpected npm: $*" >&2; return 1;; esac; }
npx() { case "$*" in *--dry-run*) echo "Install location: $tmp_mcp/pw";; *"install chromium"*) : ;; *) echo "unexpected npx: $*" >&2; return 1;; esac; }
HOME="$tmp_mcp" CONFIG_SKIP_MCP='' main >/dev/null 2>&1
unset -f find_claude uname command npm npx
grep -qF -- "mcp add -s user playwright -- npx @playwright/mcp@$MCP_VERSION --isolated --headless --executable-path $tmp_mcp/pw/chrome-linux64/chrome" "$CLAUDE_ARGV_LOG" \
  || fail "main() must register --executable-path <bundled chrome> on headless Linux w/o system chromium; got: $(cat "$CLAUDE_ARGV_LOG")"
unset CLAUDE_ARGV_LOG
pass "setup-playwright-mcp.sh main() wires --executable-path to the bundled Chromium (headless Linux, no system browser)"

# 10. Fresh-host plugin guard: the official marketplace must be ADDED before
#     superpowers is INSTALLED. On a freshly-imaged host the marketplace isn't
#     pre-registered, so install-before-add fails ("Plugin not found in
#     marketplace"). The plugin block runs under CONFIG_SKIP_PLUGINS=1 here, so
#     only this static order check can catch a future reorder/drop of the add.
mkt_ln=$(grep -n 'plugin marketplace add anthropics/claude-plugins-official' justfile | head -1 | cut -d: -f1)
sp_ln=$(grep -n 'plugin install superpowers@claude-plugins-official' justfile | head -1 | cut -d: -f1)
[[ -n "$mkt_ln" && -n "$sp_ln" && "$mkt_ln" -lt "$sp_ln" ]] \
  || fail "justfile: 'marketplace add anthropics/claude-plugins-official' (line ${mkt_ln:-none}) must precede 'plugin install superpowers@…' (line ${sp_ln:-none})"
pass "official marketplace added before superpowers install (fresh-host provisioning)"

echo
echo "all install smoke checks passed"
