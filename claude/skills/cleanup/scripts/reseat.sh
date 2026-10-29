#!/usr/bin/env bash
# reseat.sh — reseat_if_ready(DIR): leave one checkout ready for `tc new` (the
# same free shape lib/pick.sh uses: on main + clean) — ONLY when doing so is safe.
# It never discards or strands work (CLAUDE.md § Git Safety). Status strings:
#   n/a                                  — not a .git repo
#   not-free: uncommitted changes        — dirty tree, left untouched
#   not-free: unmerged branch <b>        — feature branch we can't prove merged
#   not-free: became ineligible during the merge check — the tree went dirty,
#                                          HEAD moved, the branch changed, or a
#                                          caller-supplied guard ($2) rejected it
#                                          during the gh call, so the merged-PR
#                                          match no longer describes it; nothing
#                                          was switched
#   ready ✓ (on main)                    — on main, clean, HEAD == origin/main
#   ready ✓ (PR #N merged → main)        — switched off a confirmed-merged branch
#   error: HEAD != origin/main           — verify failed; left as-is
#
# The merged gate (step 4): a merged PR matched by branch NAME alone is not
# enough — a reused branch name matches an OLDER merged PR even when the current
# HEAD carries new unmerged commits, which would strand that work. Require the
# merged PR's head SHA to equal the current HEAD. (A HEAD-is-ancestor-of-
# origin/main check would be wrong — this repo squash-merges, so a merged
# branch's commits are never ancestors of main; the head-SHA match survives
# squash.) Uncertainty (gh unauthed / no remote / network) defaults to
# not-merged: never switch off a branch we can't confirm is in main.
#
# The merged query is pinned to `--base main`: a stacked PR merged into its
# PARENT branch is merged, but its work is NOT in main, so reseating its checkout
# would strand exactly what `PR_LIFECYCLE.md` § Spec-doc PRs and stacking warns
# about. Accepted false negative: once that parent later merges, the child's work
# IS in main, but its own PR still records the parent as base — so the checkout
# stays parked rather than being reclaimed. Staying parked is the safe direction,
# and the alternative is an ancestry walk this doesn't earn.
#
# A master-default repo on a feature branch reports not-free rather than being
# reseated — default-branch detection for a repo shape the fleet doesn't have
# would be net-LOC for a non-occurring case (CODING_STANDARDS § Anti-Bloat).
set -euo pipefail

reseat_if_ready() { # reseat_if_ready <abs-checkout-path> [pre-switch-guard-fn] — prints one status string
  local DIR=$1 br head merged suffix="on main"
  [ -d "$DIR/.git" ] || { echo "n/a"; return 0; }
  if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    echo "not-free: uncommitted changes"; return 0
  fi
  br=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$br" = main ] || [ "$br" = master ]; then
    # On the default branch already — sync, then verify below. A pull failure
    # (network) falls through to the verify rather than aborting the run.
    git -C "$DIR" pull --ff-only >/dev/null 2>&1 || true
  else
    head=$(git -C "$DIR" rev-parse HEAD)
    # gh failure (no remote / unauthed / network) must fall through to not-free,
    # NOT abort under `set -euo pipefail` — tolerate it, leave $merged empty.
    # The gh runs inside $DIR so it resolves THAT repo, not the caller's.
    merged=$(cd "$DIR" && gh pr list --head "$br" \
      --state merged --base main --json number,headRefOid \
      --jq ".[] | select(.headRefOid==\"$head\") | .number" 2>/dev/null | head -1) || merged=""
    if [ -n "$merged" ]; then
      # The gh query above is a network call lasting seconds — long enough for an
      # agent to open a pane, start editing, commit, or switch branches, and a
      # caller's claim lock excludes other CLAIMERS, not that. So everything read
      # before it is stale here. Re-check all three inputs the merged-PR match
      # rests on: the tree, $head, and $br — a checkout onto a DIFFERENT branch
      # at the same commit leaves the first two identical, so only $br sees it,
      # and that is the branch `checkout main` would yank away. $2 is an
      # optional predicate taking <dir>, for what only the caller can see: §1a2
      # passes the tmux half of "idle", which needs lib/pick.sh and so cannot
      # live here — and which Step 6's callers must NOT have, since they reseat
      # the session's own checkout, where a live pane is expected. That split is
      # why the guard is a parameter rather than baked in. Sourced callers only;
      # §1a2 is the only caller that supplies one.
      if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ] \
         || [ "$(git -C "$DIR" rev-parse HEAD)" != "$head" ] \
         || [ "$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)" != "$br" ] \
         || { [ -n "${2:-}" ] && ! "$2" "$DIR"; }; then
        echo "not-free: became ineligible during the merge check"; return 0
      fi
      # This exact work is in main — switching loses nothing.
      { git -C "$DIR" checkout main && git -C "$DIR" pull --ff-only; } >/dev/null 2>&1 || true
      suffix="PR #$merged merged → main"
    else
      echo "not-free: unmerged branch $br"; return 0
    fi
  fi
  # Verify after any pull/checkout. False (local-only commits, force-pushed
  # upstream, checkout failure above) → leave as-is.
  if [ "$(git -C "$DIR" rev-parse HEAD)" = "$(git -C "$DIR" rev-parse origin/main 2>/dev/null)" ]; then
    echo "ready ✓ ($suffix)"
  else
    echo "error: HEAD != origin/main"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  reseat_if_ready "${1:?usage: reseat.sh <abs-checkout-path>}"
fi
