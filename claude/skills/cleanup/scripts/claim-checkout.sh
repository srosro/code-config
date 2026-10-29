#!/usr/bin/env bash
# claim-checkout.sh — /cleanup Step 1: claim + sync a free code-config checkout.
#
# Candidates, in order: the legacy bare ~/Hacking/code-config (the only checkout
# on a not-yet-migrated host), then slots code-config0..9. A candidate qualifies
# when ALL of: (1) is a .git repo, (2) origin matches $ORIGIN (a clean clone of a
# *different* repo at that path must not be claimed), (3) it passes `_cc_accept`
# UNDER the claim lock — see that function's doc comment, which owns the full
# condition. The lock only guards concurrent claims, not a user dirtying,
# branching or opening the slot since the pre-check, so the re-check is what
# makes the pre-check safe to be cheap (same shape as `tc claim`).
# Busy candidates are skipped, never branch-switched (CLAUDE.md § Git Safety —
# leave the user's in-flight work alone). If none qualify, §1a2 reclaims a leaked
# slot; only then does §1b auto-clone the lowest unused slot.
# Claims use lib/claim.sh's atomic mkdir (POSIX-atomic winner-decider;
# 4h staleness reclaim), so two concurrent /cleanup runs get a clean winner/loser.
#
# Output (stdout, final two lines):  CONFIG_DIR=<abs path>   CLAIM_LOCK=<lock path>
# The caller MUST release the claim at the end of the run (release-claim.sh); a
# crashed run self-heals via the 4h staleness rule in lib/claim.sh.
set -euo pipefail

CONFIG_DIR=""
CLAIM_LOCK=""

# Legacy bare first, then slots 0-9.
candidates=(~/Hacking/code-config ~/Hacking/code-config{0..9})

# Trust anchor: the INSTALLED clone (~/services/code-config — what
# ~/.local/bin/tc resolves through; INSTALL.md step 1), never a dev candidate.
# The ~/Hacking candidates are data to validate, not code to source — sourcing a
# candidate's lib/claim.sh (or deriving $ORIGIN from it) would let a wrong-origin
# slot execute shell before any validation and self-bless its remote as canonical.
# The symbol checks matter because an installed clone behind main can carry an
# OLD claim.sh/pick.sh lacking claim_lock_path/_tcp_eligible — fail loud with the
# pull hint. (Without the pick.sh check, a missing _tcp_eligible fails _cc_free
# for EVERY candidate, so §1a silently skips all free slots and auto-clones a
# fresh one per run until the slots are burned.)
SVC=~/services/code-config
{ grep -q 'claim_lock_path()' "$SVC/lib/claim.sh" && grep -q '_tcp_eligible()' "$SVC/lib/pick.sh"; } 2>/dev/null \
  || { echo "FATAL: $SVC/lib/{claim,pick}.sh missing or predate claim_lock_path/_tcp_eligible — install per INSTALL.md, or pull main in the installed clone (git -C $SVC pull --ff-only origin main)"; exit 1; }

. "$SVC/lib/claim.sh"   # claim_slot / release_slot / claim_lock_path
. "$SVC/lib/pick.sh"    # _tcp_eligible: on main/master + clean + not tmux-busy
# A SIBLING, not a $SVC lookup — the two ship in one commit, so this binds the
# version that shipped with this file and leaves no skew for the checks above.
. "${BASH_SOURCE[0]%/*}/reseat.sh"   # reseat_if_ready: merged-head-gated switch to main
# A trailing .git or / is cosmetic — same remote. Normalize both sides before
# comparing so a slot cloned with a .git suffix is still claimable, not skipped
# as wrong-origin (mirrors the _norm in tc's setup provision snippet).
_ccnorm() { local u=${1%/}; printf '%s\n' "${u%.git}"; }
ORIGIN=$(_ccnorm "$(git -C "$SVC" remote get-url origin)")
_cc_free() { [ "$(git -C "$1" symbolic-ref --short HEAD 2>/dev/null)" = main ] && _tcp_eligible "$1"; }
# What §1a2 may hand to reseat_if_ready: a genuine feature branch, nobody in it.
# `master` is excluded because reseat treats it as a default branch and pulls it —
# cleanup would mutate a branch it can never claim, since _cc_free wants exactly
# `main`. Detached HEAD (empty) is excluded for the same reason.
# Mirrors the clean+busy conjunct of lib/pick.sh's _tcp_eligible, deliberately:
# that one also requires main/master, which is the opposite of what §1a2 wants.
_cc_reclaimable() { # _cc_reclaimable <dir>
  case "$(git -C "$1" symbolic-ref --short HEAD 2>/dev/null)" in
    main|master|"") return 1 ;;
  esac
  [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ] && ! _tcp_busy "$1"
}
# THE accept gate — the one both §1a and §1a2 run under the claim lock, so there
# is a single path to reason about and to test. A slot qualifies when it is on
# exactly `main` (not `master`: cleanup's writers push `main` only), clean, with
# no tmux pane running a command in it, pullable, and identical to `origin/main`.
# The pull is not proof of that last conjunct: `--ff-only` succeeds trivially on
# a branch strictly AHEAD of its remote, which is how someone's unpushed commit
# on `main` would otherwise ride out on cleanup's own `git push origin main`.
_cc_accept() { # _cc_accept <dir>
  _cc_free "$1" && git -C "$1" pull --ff-only origin main \
    && [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/main 2>/dev/null)" ]
}

# §1a — one claim loop, identical for every candidate. A lost claim race, or any
# condition `_cc_accept` rejects → release (where held) and move to the next, so
# a later run can re-claim this candidate.
for dir in "${candidates[@]}"; do
  [ -d "$dir/.git" ] || continue
  [ "$(_ccnorm "$(git -C "$dir" remote get-url origin 2>/dev/null)")" = "$ORIGIN" ] || continue
  _cc_free "$dir" || continue   # cheap pre-check; _cc_accept re-asserts under the lock
  lock=$(claim_lock_path "$dir")
  claim_slot "$lock" || continue   # lost the race / already claimed → next candidate
  if _cc_accept "$dir"; then
    CONFIG_DIR="$dir"
    CLAIM_LOCK="$lock"
    break
  fi
  release_slot "$lock"
done

# §1a2 — reclaim a slot parked on a branch whose PR already merged. Nothing else
# returns a slot to main (Step 6 reseats only the claimed slot and the caller's),
# so without this the fleet drains one slot per merged PR. Runs only after §1a
# found nothing, so a free slot always wins and nothing is mutated while one is
# idle. `reseat_if_ready` is the sole authority on whether switching is safe;
# `_cc_reclaimable` (above) is the gate in front of it.
if [ -z "$CONFIG_DIR" ]; then
  for dir in "${candidates[@]}"; do
    [ -d "$dir/.git" ] || continue
    [ "$(_ccnorm "$(git -C "$dir" remote get-url origin 2>/dev/null)")" = "$ORIGIN" ] || continue
    _cc_reclaimable "$dir" || continue
    lock=$(claim_lock_path "$dir")
    claim_slot "$lock" || continue
    # Re-check BEFORE the mutation, not after: reseat_if_ready is what performs
    # the `checkout main`, so a gate placed after it would decline to claim a
    # slot it had already switched under an agent that opened the pane since the
    # pre-check. reseat has no tmux awareness of its own — this is the only
    # thing standing between it and a contested checkout.
    _cc_reclaimable "$dir" || { release_slot "$lock"; continue; }
    # reseat re-reads the tree, HEAD and the branch immediately before it
    # switches, so anything an agent entering mid-query has WRITTEN is caught
    # there. What only we can see is tmux, and the gap that matters is a pane
    # that started a build after the check above and has not written yet: the
    # gh call is seconds long, and _cc_accept declining afterwards does not undo
    # a switch. So the same predicate rides in as reseat's pre-switch guard.
    reseat_if_ready "$dir" _cc_reclaimable >/dev/null
    # Then the same accept gate §1a uses — reseat's own status can't stand in for
    # it, since reseat never looks at tmux.
    if _cc_accept "$dir"; then
      CONFIG_DIR="$dir"
      CLAIM_LOCK="$lock"
      break
    fi
    release_slot "$lock"
  done
fi

# §1b — auto-clone fallback: every candidate busy/claimed/unpullable/wrong-origin.
# Reversible (delete the dir later); cloning keeps cleanup running rather than asking.
if [ -z "$CONFIG_DIR" ]; then
  for N in 0 1 2 3 4 5 6 7 8 9; do
    candidate=~/Hacking/code-config$N
    [ -d "$candidate" ] && continue
    lock=$(claim_lock_path "$candidate")
    # Claim the slot atomically BEFORE cloning — otherwise two concurrent runs
    # both clone into the same slot. claim_slot handles stale reclaim too.
    if claim_slot "$lock"; then
      # Release if clone fails (network, auth, disk) so a later run can retry.
      if ! git clone "$ORIGIN" "$candidate"; then
        release_slot "$lock"
        continue
      fi
      CONFIG_DIR="$candidate"   # a fresh clone is already current — no pull
      CLAIM_LOCK="$lock"
      break
    fi
  done
  [ -n "$CONFIG_DIR" ] || { echo "FATAL: every code-config candidate (legacy bare + slots 0-9) is busy or claimed, none was reclaimable (parked on an unmerged branch, or holding unpushed commits), and no slot is clonable — re-run after freeing one"; exit 1; }
fi

echo "CONFIG_DIR=$CONFIG_DIR"
echo "CLAIM_LOCK=$CLAIM_LOCK"
