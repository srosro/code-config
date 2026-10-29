# code-config

One engineer's personal engineering config for Claude Code and Codex: global
rules, skills, hooks, and a fleet tmux/checkout CLI. MIT-licensed and published
so others can borrow pieces; it is opinionated, not a framework. See
`INSTALL.md` for setup and the full inventory of symlinks and host-local side
effects.

## Layout

- `claude/CLAUDE.md` — global rules loaded into every Claude session.
- `claude/CODING_STANDARDS.md`, `REVIEW_PRACTICES.md`, `TESTING.md`, `AUTHORING.md`, `PR_LIFECYCLE.md` — referenced documents for specific domains.
- `claude/skills/` — Claude Code skills invoked via slash commands or that auto-activate on trigger phrases. `zoom-out` and `agent-dispatch-brief` are **vendored** from [naveenspark/fancy-pants](https://github.com/naveenspark/fancy-pants) (MIT — see `claude/skills/FANCY_PANTS_LICENSE`) — copied verbatim so `just install` symlinks them onto every host like any other skill. To refresh them, re-copy the two dirs from upstream.
- `codex/AGENTS.md` — the concise Codex-first global baseline.
- `codex/skills/` — repo-owned Codex-native workflows installed into the
  standard `~/.agents/skills/` discovery root. The 14-skill
  [obra/superpowers](https://github.com/obra/superpowers) suite is installed as
  its official Codex plugin, pinned to release `v6.3.0` commit
  `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`, so its skills retain names such as
  `$superpowers:systematic-debugging`.
- `tc` (+ `lib/fleet.sh`, `lib/pick.sh`, `lib/claim.sh`) — the fleet tmux/checkout CLI (see below). `just install` symlinks `tc` into `~/.local/bin`; the `lib/` helpers resolve relative to it.
- `aliases.sh` — fleet shell aliases sourced from your interactive shell rc
  (`~/.bashrc` and/or `~/.zshrc`) by `just install`: `goclaude` and `gocodex`;
  Codex retains its normal sandbox and approval boundary.

`just install` installs both payloads. Use `just install-claude` or
`just install-codex` to update only one. The Codex installer owns `AGENTS.md`,
the repo-native skills under `codex/skills`, and the pinned Superpowers plugin;
it leaves authentication, memories, history, and sessions local to each
machine.

## `tc` — fleet tmux/checkout tool

Collapses the `ssh -t <host> 'tmux new -A -s …'` + `cd ~/Hacking/<repo>` ritual into one command, with consistent `<tag><N>-<host>` session names and the right start dir. Checkouts are uniform numbered slots `~/Hacking/<repo>0..<repo>9`. `<repo>` accepts a short tag (`kwr`) or the full dir name (`knightwatch-reviewer`).

```sh
tc <repo> <N> <host>        # attach/create slot N:  ~/Hacking/<repo><N>  → <tag><N>-<host>
tc new <repo> <host>        # next FREE workspace (on main + clean + not busy), scanning <repo>0..9
tc claim <repo> <branch> [N]  # headless: claim a free local slot, or exact slot N; checkout -b <branch>
tc setup <repo> <host> [url]  # clone <repo>0..<repo>9 on <host> (idempotent)
```

`tc` needs a host table at `~/.config/code-config/fleet-hosts` (override with `CODE_CONFIG_FLEET_HOSTS`), one `<host> <user> [alias]` row per line; host-dependent `tc` commands (connect, `new`, `setup`) and the fleet helpers fail loudly without it; `tc claim` is local and still works. `tests/fixtures/fleet-hosts` shows the shape; the optional alias gives a host one short name (a row `laptop-pro alice lp` lets `tc plow 5 lp` reach it). Edit the tag map (short tag → repo dir) at the top of `lib/fleet.sh`. Running `tc … <thishost>` runs tmux locally instead of SSH-to-self. `tc setup` supersedes the old `clone-siblings.sh`: it resolves the git URL from `<repo>0`'s `origin` — falling back to a legacy bare `~/Hacking/<repo>` checkout — or takes an explicit `[url]`. A legacy bare checkout is otherwise ignored: `tc` no longer attaches to it, scans it, or clones it, so fleets migrate organically to the numbered slots.

A remote host needs `tmux` resolvable from a **non-login** shell — `ssh host cmd` gets a bare PATH, so a Homebrew or `~/.local/bin` tmux is invisible unless `~/.zshenv` adds its dir. Linux hosts get this free (`/usr/bin/tmux`); macOS ones may not.

`tc` ssh's to the bare short hostname, so it must resolve from the calling host (MagicDNS short names, or `~/.ssh/config` entries).

## Operator overlay

The author's private fleet and agent material lives in a separate repo, `code-config-private`, installed on top of this one (`just install` there, after this repo's). It provides:

- `~/.claude/OPERATOR.md` and `~/.codex/OPERATOR.md` — operator-specific rules; the last line of `claude/CLAUDE.md` imports the former via `@~/.claude/OPERATOR.md`.
- the `tailscale-ssh`, `deploy`, and `latch` skills in `~/.claude/skills/`.
- the fleet host table at `~/.config/code-config/fleet-hosts`.

Without the overlay everything still works except `tc`/fleet helpers (no host table) and those three skills; the missing `@` import is harmless.

## Conventions

### `## Top Rules` tier

Each major corpus file may open with a `## Top Rules` section — up to 5 short `**Name** — tagline → § Section` pointers naming the most load-bearing rules in the file. The tier shifts over time as the `/cleanup` skill **auto-nudges** cited rules up (Track A — reordering only, committed to `main`, no review): rules that prove load-bearing climb; rules that don't drift down as others rise. The corpus self-sorts over many sessions.

The tier entries are **pointers**, not duplicated canonical rules. The full rule lives in its section; the tier is just a fast-scan index.

Only hand-curated `claude/*.md` files participate in ranking — see `claude/skills/cleanup/SKILL.md` § Step 2 for the current exclusion list (auto-tuned files like `COMMENT_REVIEW_MISTAKES.md` and the model spec `CLEANUP_RANKING_MODEL.md` are skipped). This `README.md` (including `## Layout` and `## Conventions`) is documentation, not part of the ranked corpus.

### `/cleanup`

Run periodically after a substantive session. It audits every user turn for avoidable hand-backs, incrementally ranks the corpus and skill indexes, prunes only semantics-neutral skill scaffolding, and stages semantic autonomy changes in `claude/PROPOSALS.md`. An operator `!` turn — a handback break they named themselves — instead routes to Track C, which may open one babysat corpus-fix PR and never merges it. `claude/skills/cleanup/SKILL.md` owns the workflow; `claude/PR_LIFECYCLE.md` § Open owns its bounded direct-`main` authority. Deterministic mechanics run from the installed `~/services/code-config` clone (the trust anchor — dev checkouts are data, not code).

### roborev — always-on local commit review

The cheap local first pass: reviews **every commit on this machine** and surfaces open findings before the next commit and before push. Base `just install` owns the Claude hooks and skill; opt-in `just install-roborev` invokes the frozen legacy installer for the binary, daemon, and git hooks, then restores code-config's Claude-hook ownership. See [`INSTALL.md` Step 6](INSTALL.md).
