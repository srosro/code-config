#!/usr/bin/env bash
# commit-track-b.sh — /cleanup Track B: secret-scan, commit + push PROPOSALS.md.
# Usage: commit-track-b.sh <config-dir>
#
# The caller (the skill) appends the proposal / +1 blocks with its Edit tool;
# this script is the deterministic git half. Rebase-retry: a proposal is a real
# learning — unlike a nudge it doesn't recur cheaply, so a commit that can't land
# SURFACES, never a silent drop. A conflict (or lost race) PARKS it on an origin
# branch and returns main to origin/main: a local-only commit on main blocks every
# later `pull --ff-only` in the checkout. Exit 0 ONLY when the push landed — the
# caller marks promoted `feedback` memories `promoted-to-proposals` on rc 0
# (never deletes them) and must NOT mark them otherwise.
set -euo pipefail
CONFIG_DIR=${1:?usage: commit-track-b.sh <config-dir>}

# Scan the WHOLE PROPOSALS.md (the only Track B write target) for secret shapes
# before staging; abort before `git add` on a match. The scanner CODE comes from
# this script's own (installed) clone — $CONFIG_DIR is a claimed candidate
# checkout, i.e. data to validate, never code to execute.
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 "$HERE/../../../hooks/secret-scan.py" --scan-file "$CONFIG_DIR/claude/PROPOSALS.md" \
  || { echo "Aborting before git add — a secret shape matched in PROPOSALS.md (may be a pre-existing entry, not just this run's append; check the whole file). Use …*** below 8 characters and last-3 otherwise + rotate, then re-run."; exit 1; }

git -C "$CONFIG_DIR" add claude/PROPOSALS.md
git -C "$CONFIG_DIR" commit -m "cleanup: record proposal(s)/+1(s) in PROPOSALS.md" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
for _ in 1 2 3; do
  if ! git -C "$CONFIG_DIR" pull --rebase origin main; then
    git -C "$CONFIG_DIR" rebase --abort 2>/dev/null || true   # leave a clean tree
    break
  fi
  if git -C "$CONFIG_DIR" push origin main; then
    echo "track-b: committed $(git -C "$CONFIG_DIR" rev-parse --short HEAD)"
    exit 0
  fi
done
PARK="cleanup/proposals-$(git -C "$CONFIG_DIR" rev-parse --short HEAD)"
if git -C "$CONFIG_DIR" push origin "HEAD:refs/heads/$PARK"; then
  git -C "$CONFIG_DIR" reset -q --keep origin/main
  echo "PROPOSALS.md commit did not land on main — parked on origin/$PARK; main is back on origin/main. Re-apply it now, resolving PROPOSALS.md by hand (no duplicate blocks):"
  echo "  git -C $CONFIG_DIR pull --ff-only origin main && git -C $CONFIG_DIR cherry-pick origin/$PARK"
  echo "then push main and delete the parked branch: git -C $CONFIG_DIR push origin --delete $PARK"
else
  echo "PROPOSALS.md commit is local-only (origin unreachable) — recover with: git -C $CONFIG_DIR pull --rebase origin main && git -C $CONFIG_DIR push origin main"
fi
exit 1
