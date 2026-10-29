#!/usr/bin/env bash
# One-time, idempotent transition from claude-config paths to code-config.
set -euo pipefail

old_paths=("$HOME/services/claude-config" "$HOME/Hacking/claude-config")
new_paths=("$HOME/services/code-config" "$HOME/Hacking/code-config")
for n in {0..9}; do
  old_paths+=("$HOME/Hacking/claude-config$n")
  new_paths+=("$HOME/Hacking/code-config$n")
done

# Preflight every move before making any, so a collision cannot leave a host
# half-migrated. Include dangling symlinks in the existence test.
for i in "${!old_paths[@]}"; do
  old=${old_paths[$i]} new=${new_paths[$i]}
  if [[ ( -e "$old" || -L "$old" ) && ( -e "$new" || -L "$new" ) ]]; then
    echo "FATAL: refusing to overwrite existing destination: $new" >&2
    exit 1
  fi
done

moved=0
for i in "${!old_paths[@]}"; do
  old=${old_paths[$i]} new=${new_paths[$i]}
  [[ -e "$old" || -L "$old" ]] || continue
  mkdir -p "${new%/*}"
  mv "$old" "$new"
  moved=$((moved + 1))
done

# GitHub redirects the old repository name, but leaving every clone pointed at
# that redirect hides incomplete migrations and can break purpose-scoped deploy
# keys. Rewrite only this repository's exact legacy origin URLs.
remotes_updated=0
for repo in "${new_paths[@]}"; do
  [[ -e "$repo/.git" || -d "$repo/.git" ]] || continue
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$origin" in
    git@github.com:srosro/claude-config|git@github.com:srosro/claude-config.git)
      git -C "$repo" remote set-url origin git@github.com:srosro/code-config.git ;;
    https://github.com/srosro/claude-config|https://github.com/srosro/claude-config.git)
      git -C "$repo" remote set-url origin https://github.com/srosro/code-config.git ;;
    *) continue ;;
  esac
  remotes_updated=$((remotes_updated + 1))
done

old_line=". \"$HOME/services/claude-config/aliases.sh\"  # claude-config fleet aliases"
new_line=". \"$HOME/services/code-config/aliases.sh\"  # code-config fleet aliases"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  tmp=$(mktemp "${TMPDIR:-/tmp}/code-config-rc.XXXXXX")
  awk -v old="$old_line" -v new="$new_line" '{ print ($0 == old ? new : $0) }' "$rc" > "$tmp"
  cat "$tmp" > "$rc"
  rm -f "$tmp"
done

echo "migrated $moved checkout path(s), updated $remotes_updated origin URL(s); run: cd ~/services/code-config && just install"
