test:
    @./smoke-install.sh
    @for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || exit 1; done

# One-time, non-overwriting upgrade for hosts installed before the repo rename.
migrate-paths:
    @./migrate-paths.sh

# Install both agent payloads. Each child recipe is also callable on its own.
install: install-claude install-codex

# Symlink Claude files into ~/.claude (idempotent; backs up pre-existing real files).
install-claude:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v jq >/dev/null || { echo "Error: jq is required (brew install jq) — needed to merge hooks into settings.json" >&2; exit 1; }
    REPO={{quote(justfile_directory() / "claude")}}
    CLAUDE_DIR="$HOME/.claude"
    BACKUP_DIR="$CLAUDE_DIR/backups/pre-symlink-$(date +%Y%m%d-%H%M%S)"

    # Refuse if any install-root path is itself a symlink. The doc and skill
    # loops below create symlinks at $CLAUDE_DIR/<name> and $CLAUDE_DIR/skills/
    # <name>; if any ancestor is a symlink into this repo, those leaf entries
    # resolve to the source files, get misclassified as legacy real targets by
    # the [[ ! -L ]] checks, and the recipe silently moves the source out of
    # claude/. Run before mkdir so a dangling ancestor symlink hits
    # this error rather than mkdir's generic "File exists".
    for path in "$CLAUDE_DIR" "$CLAUDE_DIR/skills"; do
        [[ -L "$path" ]] && { echo "Error: $path is a symlink — remove it before running just install" >&2; exit 1; }
    done

    mkdir -p "$CLAUDE_DIR/skills"

    for doc_path in "$REPO"/*.md; do
        name="$(basename "$doc_path")"
        if [[ -e "$CLAUDE_DIR/$name" && ! -L "$CLAUDE_DIR/$name" ]]; then
            mkdir -p "$BACKUP_DIR"
            mv "$CLAUDE_DIR/$name" "$BACKUP_DIR/$name"
            echo "backed up $name"
        fi
        ln -sfn "$doc_path" "$CLAUDE_DIR/$name"
        echo "linked $name"
    done

    # Delete-aware: drop any doc or skill symlink this repo owns whose source
    # was removed from code-config. Without this, deleting a doc or skill from
    # the repo leaves a dangling ~/.claude/<name> or ~/.claude/skills/<name>
    # symlink on every already-installed host. Scoped to links pointing into
    # $REPO so user-owned files and links from other sources are never touched.
    for entry in "$CLAUDE_DIR"/*.md "$CLAUDE_DIR"/skills/*; do
        [[ -L "$entry" ]] || continue
        tgt="$(readlink "$entry")"
        case "$tgt" in
            "$REPO"/*.md|"$REPO"/skills/*) [[ -e "$tgt" ]] || { rm "$entry"; echo "pruned removed $(basename "$entry")"; } ;;
        esac
    done

    for skill_path in "$REPO"/skills/*/; do
        name="$(basename "$skill_path")"
        target="$CLAUDE_DIR/skills/$name"
        if [[ -e "$target" && ! -L "$target" ]]; then
            mkdir -p "$BACKUP_DIR"
            mv "$target" "$BACKUP_DIR/skill-$name"
            echo "backed up skill $name"
        fi
        ln -sfn "${skill_path%/}" "$target"
        echo "linked skill $name"
    done

    # Hooks: symlink the hooks dir, then merge the canonical `hooks` block into
    # ~/.claude/settings.json. settings.json is a real machine-local file (not
    # symlinked), so the merge is an idempotent append-and-dedupe merge — mirroring
    # INSTALL.md step 4's jq merge for skipDangerousModePermissionPrompt. The
    # hook commands use $HOME-relative paths (resolved by the shell at hook-run
    # time) so they work across hosts with different usernames.
    if [[ -e "$CLAUDE_DIR/hooks" && ! -L "$CLAUDE_DIR/hooks" ]]; then
        mkdir -p "$BACKUP_DIR"
        mv "$CLAUDE_DIR/hooks" "$BACKUP_DIR/hooks"
        echo "backed up hooks"
    fi
    ln -sfn "$REPO/hooks" "$CLAUDE_DIR/hooks"
    echo "linked hooks"

    SETTINGS="$CLAUDE_DIR/settings.json"
    [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
    tmp_settings="$(mktemp "$SETTINGS.XXXXXX")"   # in-dir temp → the mv below is an atomic rename
    # Append our hook entries, preserving every other key and every hook the
    # user already has (including other entries in the same event arrays). A
    # plain `jq '*'` deep-merge REPLACES arrays, which would silently drop the
    # user's other PostToolUse/UserPromptSubmit hooks — so we concat the owned
    # event arrays and `unique` them. `unique` makes it idempotent: re-running
    # install dedupes our identical entry instead of stacking copies.
    #
    # Migration prune: roborev's Claude hooks now live here, while the frozen
    # legacy installer still writes its former `*/roborev/claude-hooks/` entries.
    # Those duplicate entries are stale after this install — matched on
    # that tail rather than `/.config/…` because XDG_CONFIG_HOME can relocate them;
    # repo-owned copies live under `/.claude/hooks/`, so this cannot over-prune —
    # left in place they would double every gate. Strip them from each matcher's
    # nested `hooks` array (NOT the whole matcher object — a hand-merged matcher
    # could co-locate one with a hook we must keep), then drop only matcher
    # objects left empty. Every other PreToolUse hook survives untouched.
    # One atomic writer for both fragments: hooks ($frag) and permission denies
    # ($deny). Nothing reads settings.json between them, so a single jq -s over the
    # original file plus both fragments — then one rename — avoids a second merge
    # seam and the intermediate partially-installed state two rewrites would leave.
    # deny: union our owned entries into permissions.deny (`unique` = idempotent).
    # Currently the `git worktree add` hard stop — the letter of the "never create
    # git worktrees" rule (denies CREATION only; remove/list/prune stay for cleanup).
    jq -s '
      def dedupe_keep_order: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
      .[0] as $cur | .[1] as $frag | .[2] as $deny
      | $cur | .hooks = ($cur.hooks // {})
      | .hooks.PreToolUse = ((.hooks.PreToolUse // [])
          | map(.hooks = [(.hooks[]? | select((.command // "") | contains("/roborev/claude-hooks/") | not))])
          | map(select((.hooks | length) > 0)))
      | (if (.hooks.PreToolUse // [] | length) == 0 then del(.hooks.PreToolUse) else . end)
      | reduce ($frag.hooks // {} | to_entries[]) as $e (
          .;
          .hooks[$e.key] = (((.hooks[$e.key] // []) + $e.value) | dedupe_keep_order)
        )
      | .permissions = (.permissions // {})
      | .permissions.deny = (((.permissions.deny // []) + ($deny.permissions.deny // [])) | unique)
    ' "$SETTINGS" "$REPO/hooks/hooks.settings.json" "$REPO/settings.deny.json" > "$tmp_settings"
    mv "$tmp_settings" "$SETTINGS"
    chmod 600 "$SETTINGS"
    echo "merged hooks and permission denies into settings.json"

    # Dotfiles + terminfo — two SEPARATE halves: (1) symlink ~/.tmux.conf, whose
    # `set -as terminal-features 'xterm-ghostty:hyperlinks'` override is what makes
    # tmux pass OSC 8 hyperlinks through; (2) install the xterm-ghostty terminfo
    # entry so the terminal resolves and remote tmux can start at all. terminfo does
    # NOT enable hyperlinks — tmux won't derive them from the `Hls` cap (verified
    # 3.6b); the override does. Together these replace tc's per-connect prelude.
    if [[ -e "$HOME/.tmux.conf" && ! -L "$HOME/.tmux.conf" ]]; then
        mkdir -p "$BACKUP_DIR"
        mv "$HOME/.tmux.conf" "$BACKUP_DIR/.tmux.conf"
        echo "backed up .tmux.conf"
    fi
    ln -sfn "{{justfile_directory()}}/tmux.conf" "$HOME/.tmux.conf"
    echo "linked .tmux.conf"

    # Ensure the per-user ~/.terminfo carries our Hls-bearing entry: tic unless it's
    # already there. Scope the guard's lookup to ~/.terminfo (not the ambient search
    # path) so a system xterm-ghostty — Hls-bearing or not — can't make us skip; this
    # per-home contract is exactly what smoke-install.sh asserts, and ncurses searches
    # ~/.terminfo first at runtime so ours wins regardless. Idempotent, quiet on re-run.
    # Skip (don't abort) where ncurses' tic is absent — e.g. a host with no tmux at
    # all — so the rest of the install still completes; tmux hosts have it.
    if ! command -v tic >/dev/null 2>&1; then
        echo "note: tic (ncurses) not found — skipping xterm-ghostty terminfo install"
    elif ! TERMINFO="$HOME/.terminfo" TERMINFO_DIRS="$HOME/.terminfo" infocmp -x xterm-ghostty 2>/dev/null | grep 'Hls=' >/dev/null; then
        TERMINFO="$HOME/.terminfo" tic -x "{{justfile_directory()}}/terminfo/xterm-ghostty.terminfo"
        echo "installed xterm-ghostty terminfo (with Hls)"
    fi

    if [[ -d "$BACKUP_DIR" ]]; then
        echo "backups: $BACKUP_DIR"
    fi

    # Put the tc CLI on PATH. lib/fleet.sh + lib/pick.sh resolve relative to the
    # symlink target, so only the entrypoint needs linking.
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    ln -sfn "{{justfile_directory()}}/tc" "$BIN_DIR/tc"
    echo "linked cli tc"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on PATH" >&2 ;; esac

    # Source the fleet shell aliases (currently just `goclaude`) so it reaches the host's
    # interactive shell. Always seed the rc the active shell ($SHELL) reads — ~/.zshrc
    # on macOS (mbp/wmp), ~/.bashrc on Linux — creating it if absent; also cover the
    # other rc when it already exists (a user who switches shells). The repo file
    # stays canonical (shell analog of the symlink model); the rc only holds a guarded
    # source line, so edits to aliases.sh propagate on the next shell. `goclaude` is an
    # interactive alias (uniquely named, not `cc`) so it never shadows the system C
    # compiler `cc` on PATH; an alias only affects typing regardless.
    ALIASES="{{justfile_directory()}}/aliases.sh"
    SRC_LINE=". \"$ALIASES\"  # code-config fleet aliases"
    case "$SHELL" in
        */zsh) primary="$HOME/.zshrc"; secondary="$HOME/.bashrc" ;;
        *)     primary="$HOME/.bashrc"; secondary="$HOME/.zshrc" ;;
    esac
    touch "$primary"
    for rc in "$primary" "$secondary"; do
        [[ -f "$rc" ]] || continue
        grep -qF "$ALIASES" "$rc" || printf '\n%s\n' "$SRC_LINE" >> "$rc"
    done
    echo "sourced fleet aliases (goclaude) from shell rc"

    # Provision the Playwright MCP server (powers the `playwright` skill),
    # per-platform. No-op once set up; self-skips without the claude CLI.
    # CONFIG_SKIP_MCP=1 skips it (smoke-install.sh sets this).
    "{{justfile_directory()}}/setup-playwright-mcp.sh"

    # Default plugins every machine should have. The headless CLI is idempotent
    # (marketplace add / plugin install no-op when already present) and writes
    # enabledPlugins + extraKnownMarketplaces into ~/.claude/settings.json itself.
    # CONFIG_SKIP_PLUGINS=1 skips it (smoke-install.sh sets this — keeps the
    # symlink checks offline). CLI resolution mirrors setup-playwright-mcp.sh's
    # find_claude: login shells on some boxes miss ~/.local/bin from PATH.
    CLAUDE_BIN="$(command -v claude || true)"
    [[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
    if [[ "${CONFIG_SKIP_PLUGINS:-}" == "1" ]]; then
        echo "skipping default plugins (CONFIG_SKIP_PLUGINS=1)"
    elif [[ -z "$CLAUDE_BIN" ]]; then
        echo "skipping default plugins — claude CLI not found"
    else
        "$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official
        "$CLAUDE_BIN" plugin marketplace add 2389-research/claude-plugins
        "$CLAUDE_BIN" plugin install superpowers@claude-plugins-official
        "$CLAUDE_BIN" plugin install test-kitchen@2389-research
        echo "installed default plugins"
    fi

    # Pointer only (not auto-run): always-on local commit review is a one-shot
    # seed install. Kept out of `install` because the seed install goes further
    # than the skippable network steps above (MCP, plugins): it mutates global
    # git config, installs a daemon, and fetches + runs the roborev binary.
    # `just install-roborev` is the supported compatibility route: it runs the
    # frozen installer for the binary, daemon, and git hooks, then restores this
    # repo's Claude-hook ownership even when legacy verification fails.
    echo "note: to enable always-on local commit review (roborev), run: just install-roborev"
    echo "      (code-config owns Claude hooks; the frozen legacy installer supplies the binary, daemon, and git hooks)"

# Install Codex-native global guidance, repo-owned skills, and the pinned
# upstream Superpowers plugin. Auth, history, memories, and sessions remain
# machine-local; the Codex CLI owns its plugin config and cache.
install-codex:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC={{quote(justfile_directory() / "codex")}}
    CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
    AGENT_SKILLS_DIR="$HOME/.agents/skills"
    BACKUP_DIR="$CODEX_DIR/backups/pre-symlink-$(date +%Y%m%d-%H%M%S)"
    SKILL_BACKUP_DIR="$HOME/.agents/backups/pre-symlink-$(date +%Y%m%d-%H%M%S)"

    for path in "$CODEX_DIR" "$CODEX_DIR/rules" "$HOME/.agents" "$AGENT_SKILLS_DIR"; do
        [[ -L "$path" ]] && { echo "Error: $path is a symlink — remove it before running just install-codex" >&2; exit 1; }
    done
    mkdir -p "$CODEX_DIR" "$AGENT_SKILLS_DIR"

    target="$CODEX_DIR/AGENTS.md"
    if [[ -e "$target" && ! -L "$target" ]]; then
        mkdir -p "$BACKUP_DIR"
        mv "$target" "$BACKUP_DIR/AGENTS.md"
        echo "backed up Codex AGENTS.md"
    fi
    ln -sfn "$SRC/AGENTS.md" "$target"
    echo "linked Codex AGENTS.md"

    # Execpolicy rules: symlink our repo-owned .rules into ~/.codex/rules/. Codex
    # scans every .rules under rules/ at startup — no config.toml pointer needed —
    # and a `forbidden` prefix rule is rejected before execution in all modes
    # (--yolo included). Use a DISTINCT filename, never default.rules: the TUI
    # writes user allow-list entries into ~/.codex/rules/default.rules, so
    # symlinking that name would send a user's "always allow" write through our
    # link into the repo. Back up a pre-existing non-symlink of our name.
    mkdir -p "$CODEX_DIR/rules"
    for rules_path in "$SRC"/rules/*.rules; do
        rname="$(basename "$rules_path")"
        rtarget="$CODEX_DIR/rules/$rname"
        if [[ -e "$rtarget" && ! -L "$rtarget" ]]; then
            mkdir -p "$BACKUP_DIR"
            mv "$rtarget" "$BACKUP_DIR/rules-$rname"
            echo "backed up Codex rules $rname"
        fi
        ln -sfn "$rules_path" "$rtarget"
        echo "linked Codex rules $rname"
    done

    # Remove links for skills deleted from this repository without touching
    # user-owned links or directories.
    for target in "$AGENT_SKILLS_DIR"/*; do
        [[ -L "$target" ]] || continue
        link=$(readlink "$target")
        case "$link" in
            "$SRC"/skills/*) [[ -e "$link" ]] || { rm "$target"; echo "pruned removed Codex skill $(basename "$target")"; } ;;
        esac
    done

    for skill in "$SRC"/skills/*/; do
        name=$(basename "$skill")
        source=${skill%/}
        target="$AGENT_SKILLS_DIR/$name"
        if [[ -e "$target" || -L "$target" ]]; then
            current=""
            [[ -L "$target" ]] && current=$(readlink "$target")
            if [[ "$current" != "$source" ]]; then
                mkdir -p "$SKILL_BACKUP_DIR"
                mv "$target" "$SKILL_BACKUP_DIR/$name"
                echo "backed up existing Codex skill $name"
            fi
        fi
        ln -sfn "$source" "$target"
        echo "linked Codex skill $name"
    done

    if [[ -d "$BACKUP_DIR" ]]; then
        echo "backups: $BACKUP_DIR"
    fi
    if [[ -d "$SKILL_BACKUP_DIR" ]]; then
        echo "skill backups: $SKILL_BACKUP_DIR"
    fi

    # Superpowers is a multi-skill distribution, so install its official Codex
    # plugin rather than copying and adapting the skill tree here. Recreate our
    # marketplace entry on every run so an existing checkout cannot silently
    # retain a different ref. Add the pinned source before retiring the older
    # curated plugin, so a fetch failure leaves the working install enabled.
    # CONFIG_SKIP_PLUGINS=1 keeps smoke/offline installs side-effect-free.
    CODEX_BIN="$(command -v codex || true)"
    [[ -z "$CODEX_BIN" && -x "$HOME/.local/bin/codex" ]] && CODEX_BIN="$HOME/.local/bin/codex"
    if [[ "${CONFIG_SKIP_PLUGINS:-}" == "1" ]]; then
        echo "skipping Codex plugins (CONFIG_SKIP_PLUGINS=1)"
    elif [[ -z "$CODEX_BIN" ]]; then
        echo "skipping Superpowers plugin — codex CLI not found"
    else
        if ! remove_output=$("$CODEX_BIN" plugin marketplace remove superpowers-dev 2>&1); then
            case "$remove_output" in
                *'is not configured or installed'*) ;;
                *) printf '%s\n' "$remove_output" >&2; exit 1 ;;
            esac
        fi
        "$CODEX_BIN" plugin marketplace add obra/superpowers --ref b36e0829c6d0140e93cfef2ca599b1b07d4a7797 >/dev/null
        "$CODEX_BIN" plugin add superpowers@superpowers-dev >/dev/null
        "$CODEX_BIN" plugin remove superpowers@openai-curated >/dev/null
        echo "installed Superpowers plugin v6.3.0 at b36e0829c6d0140e93cfef2ca599b1b07d4a7797"
    fi

# The roborev review rubric + its sync now live in the seed that owns roborev:
# plow-pbc/seed-auto-roborev (ref/sync-review-config.sh). It configures the
# REVIEWER, not the agent — nothing in it is read by Claude as guidance — which
# is the same split knightwatch already uses for its own rubric. The seed's
# install.sh runs it, so a fresh machine lands configured; to re-sync by hand
# after editing a REVIEW.md. NOTE: a host seeded BEFORE seed-auto-roborev#26
# has no such file — `just install` deliberately doesn't touch roborev, so
# re-run `just install-roborev` once to get it:
#   ~/.config/roborev/sync-review-config.sh          # all tracked repos
#   ~/.config/roborev/sync-review-config.sh <repo>   # just one
#   ~/.config/roborev/sync-review-config.sh --check  # read-only: is it in sync?

# Compatibility route through the frozen seed installer. It still owns the
# binary, daemon, and git hooks; code-config owns the Claude hooks and reapplies
# them on every exit path so a failed legacy verification cannot leave doubles.
install-roborev:
    #!/usr/bin/env bash
    set -euo pipefail
    JUSTFILE={{quote(justfile_directory() / "justfile")}}
    restore_claude_hooks() {
        rc=$?
        trap - EXIT
        if ! CONFIG_SKIP_MCP=1 CONFIG_SKIP_PLUGINS=1 just --justfile "$JUSTFILE" install-claude; then
            echo "FATAL: could not restore code-config's Claude hooks after the legacy roborev install" >&2
            exit 1
        fi
        if [[ "$rc" -eq 0 ]]; then
            echo "✓ roborev binary, daemon, git hooks, and code-config Claude hooks installed + verified"
        fi
        exit "$rc"
    }
    trap restore_claude_hooks EXIT
    # Fetch the reviewed seed-auto-roborev revision, then run its fail-loud install + verify. See
    # INSTALL.md Step 6 for the full hook stack. Idempotent; the seed's install.sh
    # fetches the pinned roborev binary itself if absent.
    SEED_COMMIT="83db20dcc8cb60b1eff73e06892b3140ec33b3d8"
    SEED_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/seed-auto-roborev"
    if [[ -d "$SEED_DIR/.git" ]]; then
        git -C "$SEED_DIR" fetch --quiet origin "$SEED_COMMIT"
    else
        git clone --quiet --no-checkout https://github.com/plow-pbc/seed-auto-roborev.git "$SEED_DIR"
    fi
    git -C "$SEED_DIR" checkout --detach --quiet "$SEED_COMMIT"
    bash "$SEED_DIR/ref/install.sh"
    bash "$SEED_DIR/ref/verify.sh"
