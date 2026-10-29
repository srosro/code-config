# Install

Set up this repo's configs on a new machine.

## 1. Clone the run-clone

The clone whose agent payloads are symlinked live into `~/.claude/` and
`~/.codex/` lives in `~/services/` (where code runs). Keep it clean on `main`.

```sh
git clone <repo-url> ~/services/code-config
```

Existing hosts installed under the old name should upgrade in place after this
change reaches `main`:

```sh
cd ~/services/claude-config
git pull --ff-only origin main
just migrate-paths
cd ~/services/code-config
just install
```

`migrate-paths` preflights every destination before changing anything, then
renames the service clone, the bare development clone, and occupied numbered
checkouts without overwriting. It also replaces only the exact installer-owned
legacy shell-rc source line and exact `srosro/claude-config` origin URLs. A
collision aborts the entire transition for manual inspection; rerunning after a
successful migration is a no-op.

For development — writing config changes and running the `cleanup` skill, which commits from it — also clone a numbered workspace slot (where you write code): `git clone <repo-url> ~/Hacking/code-config0` (`tc setup cc <host>` fills the rest of `code-config0..9` for parallel checkouts). An existing legacy un-numbered `~/Hacking/code-config` clone (a normal working clone, just at the old path) keeps working — `/cleanup` claims it first while it exists. Dev checkouts are never symlinked into `~/.claude`.

## 2. Run install

Requires [`just`](https://github.com/casey/just) and [`jq`](https://jqlang.github.io/jq/) (`brew install just jq` on macOS). `jq` is used to merge the canonical hook block in `claude/hooks/hooks.settings.json` (the two capture hooks, the knightwatch in-flight push gate, and roborev's pre-commit context, pre-push, and pre-checkout hooks) into `~/.claude/settings.json`.

```sh
cd ~/services/code-config
just install
```

Symlinks `claude/` docs and skills into `~/.claude/`, the `tc` CLI into `~/.local/bin`, `~/.tmux.conf`, and the hook directory; it also installs terminfo, provisions Playwright MCP and default plugins, and sources the fleet aliases from the active shell rc. The idempotent settings merge preserves unrelated configuration while adding directive capture, the knightwatch in-flight gate, and roborev's pre-commit context, pre-push, and pre-checkout hooks. The frozen legacy roborev installer still supplies the binary, daemon, and git hooks; Step 6's supported compatibility route always reapplies this Claude-hook inventory afterward. Existing real files and skill directories are backed up before symlinking, and install-root symlinks are refused. `OPERATOR.md`, the three operator skills, and `fleet-hosts` are not part of this list; they come from the overlay below.

The same aggregate install links `codex/AGENTS.md` into `~/.codex/` and each
Codex-native skill into `~/.agents/skills/`; it does not import Claude
references or skills. It also installs the official
[`obra/superpowers`](https://github.com/obra/superpowers) Codex plugin at release
`v6.3.0`'s immutable commit `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`.
This intentionally updates Codex's machine-local plugin configuration and cache;
auth, memories, history, and sessions remain local.
Use `just install-claude` or `just install-codex` to update only one payload.
Restart Codex after installation so the 14 namespaced skills, including
`$superpowers:systematic-debugging`, appear in the next session.

### Operator overlay (optional)

The author's private overlay, `code-config-private`, adds `~/.claude/OPERATOR.md` (imported by `CLAUDE.md`), `~/.codex/OPERATOR.md`, the `tailscale-ssh`, `deploy`, and `latch` skills, and the `tc` host table `~/.config/code-config/fleet-hosts`. Clone it beside this repo (`~/services/code-config-private` on a deploy host) and run `just install` there after the step above, then verify:

```sh
readlink ~/.claude/OPERATOR.md ~/.config/code-config/fleet-hosts
```

Without it, install is complete but host-dependent `tc` commands (connect, `new`, `setup`) and the fleet helpers fail loudly until you create `fleet-hosts` yourself (`<host> <user> [alias]` per line; see `tests/fixtures/fleet-hosts`); `tc claim` is local and still works.

## 3. Default plugins

**`just install` provisions these automatically** via the headless plugin CLIs
(idempotent; each side self-skips when its CLI is absent;
`CONFIG_SKIP_PLUGINS=1 just install` skips both):

- `superpowers@claude-plugins-official` (adds the `anthropics/claude-plugins-official` marketplace first)
- `test-kitchen@2389-research` (adds the `2389-research/claude-plugins` marketplace first)

For Codex, it replaces the stale `superpowers@openai-curated` registration with
`superpowers@superpowers-dev`, sourced directly from `obra/superpowers` at the
pinned `v6.3.0` commit `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`. The
installer recreates that marketplace registration on each run so an older local
ref cannot silently win.

This populates `~/.claude/plugins/` and enables them in `~/.claude/settings.json`. To add a default plugin for every machine, append both its `claude plugin marketplace add <owner>/<repo>` and its `claude plugin install` to the plugins block in the `install` recipe — add the marketplace explicitly **even for the official one**, or a freshly-imaged host (where it isn't pre-registered) fails the install with "Plugin not found in marketplace". Verify with `claude plugin list`.

## 4. (Optional) Skip dangerous-mode permission prompt

```sh
jq '. + {skipDangerousModePermissionPrompt: true}' ~/.claude/settings.json \
  > ~/.claude/settings.json.tmp && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

## 5. Playwright MCP server (browser debugging)

Powers the `playwright` skill (front-end debugging in a real browser). **`just install` provisions this automatically** — `setup-playwright-mcp.sh` runs at the end of the install and registers the server per-machine (it lives in `~/.claude.json`, outside the symlink model), picking browser flags by platform:

- **macOS** — the pinned `@playwright/mcp` (version in `setup-playwright-mcp.sh`) with `--isolated`, headed so you can watch; Chromium installs on first use.
- **Linux with a system Chromium** (e.g. the Pi kiosk) — reuses it via `--executable-path`, `--headless`. No download.
- **Linux without one** (e.g. a headless server) — downloads Playwright's matching Chromium to `~/.cache` (no sudo), then registers `--executable-path` to *that* bundled binary, `--headless`. The explicit path is load-bearing: without it the server falls back to the absent `chrome` channel and every navigation fails.

On Linux the script keeps the Chromium sandbox on (page content is untrusted) and adds `--no-sandbox` **only** on a host where the sandboxed launch test actually fails — e.g. a kernel with unprivileged user namespaces disabled. So the sandbox stays wherever it works, and a host that can't sandbox still gets a working browser automatically, no manual flag.

`--isolated` gives a fresh in-memory profile each session (no access to your real Chrome logins). The script also allowlists the two screen-only read-only tools (`browser_snapshot`, `browser_take_screenshot`); `browser_console_messages` / `browser_network_requests` stay gated because console/network can carry tokens not visible on the page. It's idempotent (re-runs no-op), self-skips when the `claude` CLI is absent, and `CONFIG_SKIP_MCP=1 just install` skips it.

The version is pinned (not `@latest`) so a fresh setup can't silently pull unreviewed browser-server code; the bundled-Chromium download derives its Playwright version from that same pin. Bump `MCP_VERSION` in `setup-playwright-mcp.sh` deliberately and re-verify the skill's tool names.

**Troubleshooting (headless Linux):** if the install's launch test reports Chromium failed to start on missing OS libs, run the one `sudo` command it prints, once on that host (no passwordless sudo needed at install time, so this step is manual):

```sh
sudo npx playwright@<version> install-deps chromium
```

Verify any host with `claude mcp list`: it should read `playwright … ✓ Connected` **and**, on Linux without a system Chromium, carry `--executable-path <bundled chrome>` in the command. `✓ Connected` only proves the MCP handshake — the browser resolves lazily on first navigation, so a missing `--executable-path` still shows Connected yet fails every navigate.

## 6. (Optional) Always-on local commit review (roborev)

Base `just install` wires the Claude hooks and skill but does not install the `roborev` binary, daemon, or git hooks. Install those once per machine through the compatibility recipe:

```
just install-roborev
```

The recipe runs [`plow-pbc/seed-auto-roborev`](https://github.com/plow-pbc/seed-auto-roborev) at reviewed commit `83db20dcc8cb60b1eff73e06892b3140ec33b3d8` for the binary, user daemon, `core.hooksPath`, `post-commit`, and `post-rewrite`, then reapplies code-config's Claude hook inventory. That final ownership restore runs even when the legacy verifier fails, so its former `~/.config/roborev/claude-hooks/*` registrations cannot remain beside the repo-owned copies and double every gate. Run this recipe rather than invoking the deprecated SEED directly.
