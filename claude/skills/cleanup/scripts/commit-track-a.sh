#!/usr/bin/env bash
# commit-track-a.sh — /cleanup Track A: commit + push corpus/skill garden edits.
# Usage: commit-track-a.sh <config-dir> <gardened-file> [<gardened-file> …]
#
# The caller applies bounded corpus nudges and semantics-neutral skill gardening;
# selection is judgment, this script is the deterministic git half. Track A
# commits DIRECTLY to main, no PR. On a genuine overlap, DROP this run's edits —
# the evidence recurs next session, so a dropped garden pass self-heals.
#
# Guardrail-scoped `reset --hard`: CLAUDE.md § Git Safety forbids it in
# general; this is the one authorized exception, gated to (a) the cleanup-owned
# $CONFIG_DIR checkout, (b) whose SOLE delta is this run's own reorder commit,
# (c) discarding only to origin/main. The "best-effort, drop on conflict"
# design is the explicit authorization. Never use this on a caller checkout.
set -euo pipefail
CONFIG_DIR=${1:?usage: commit-track-a.sh <config-dir> <gardened-file> …}; shift
[ $# -ge 1 ] || { echo "FATAL: no gardened files given"; exit 1; }

git -C "$CONFIG_DIR" add "$@"   # explicit paths — never git add -A / a directory
git -C "$CONFIG_DIR" commit -m "cleanup: garden cited rules and skills" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git -C "$CONFIG_DIR" push origin main || {
  # Separate transient/network failure from a genuine overlapping garden conflict:
  if ! git -C "$CONFIG_DIR" fetch origin main; then
    echo "track-a committed but couldn't reach origin — left local; recover with: git -C $CONFIG_DIR pull --rebase origin main && git -C $CONFIG_DIR push origin main"
  elif git -C "$CONFIG_DIR" rebase origin/main; then
    git -C "$CONFIG_DIR" push origin main || echo "track-a rebased but re-push failed (concurrent push / hook / auth) — recover with: git -C $CONFIG_DIR pull --rebase origin main && git -C $CONFIG_DIR push origin main"
  else
    git -C "$CONFIG_DIR" rebase --abort
    git -C "$CONFIG_DIR" reset --hard origin/main   # genuine overlap → drop this run's edits (recurs)
    echo "track-a: garden edits dropped on conflict (they recur next session)"
    exit 0
  fi
}
echo "track-a: committed $(git -C "$CONFIG_DIR" rev-parse --short HEAD)"
