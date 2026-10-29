# code-config fleet shell aliases — sourced from your interactive shell rc
# (~/.bashrc and/or ~/.zshrc) by `just install`.
# This file is the canonical source of truth; machines point in (the shell analog
# of the ~/.claude symlink model), so edits here propagate to every host on the
# next shell — no re-install needed. POSIX/bash/zsh-compatible alias syntax only.

# goclaude — jump to main, pull, and launch Claude Code with permission prompts skipped.
# Named uniquely (not `cc`) so it never collides with the system C compiler `cc`
# (`/usr/bin/cc`, also invoked by make/pip/etc.) — even as an interactive alias, `cc`
# was too overloaded a name to safely shadow. Kept as an interactive alias rather than
# a ~/.local/bin/goclaude symlink like `tc`: it only affects what you type at a prompt.
alias goclaude='git checkout main && git pull --ff-only origin main && claude --dangerously-skip-permissions'

# gocodex — update the checkout and launch Codex with its normal sandbox and
# approval boundary.
alias gocodex='git checkout main && git pull --ff-only origin main && codex'
