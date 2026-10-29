#!/usr/bin/env bash
# Tests for the /cleanup extracted mechanics (skills/cleanup/scripts/*.sh).
# Behavior under test (user-visible contracts, not internals):
#   claim-checkout.sh   — claims the first FREE candidate, skips dirty/wrong-origin,
#                         auto-clones on exhaustion, leaves the lock HELD
#   release-claim.sh    — releases that lock
#   reseat.sh           — the status-string contract incl. the merged-HEAD gate
#   stash-untracked.sh  — untracked-only /tmp stash + reseat re-call; aborts on
#                         tracked modifications
#   commit-track-a.sh   — pushes bounded corpus/skill gardening; DROPS it on genuine conflict
#   commit-track-b.sh   — secret-scan gate; rebase-retry; a conflict PARKS the commit
#                         on an origin branch and returns main to origin/main (rc 1)
set -u
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
SCRIPTS="$HERE/../claude/skills/cleanup/scripts"

commit() { git -C "$1" -c user.email=t@t -c user.name=t commit -q "${@:2}"; }

# A `gh` stub mirroring real gh: it advertises merged PR #7 only when the args
# pin $GH_STUB_MERGED_SHA (so a reused branch name whose merged PR was for an
# older head still reads as unmerged) AND the requested `--base` matches the
# PR's own base, $GH_STUB_PR_BASE (default main) — which is how a stacked PR
# merged into its PARENT reads as not-in-main. An ABSENT --base is no filter at
# all (real gh semantics), which is what makes the stacked case falsifiable:
# drop `--base main` from the query and the child PR matches again.
# Both are reseat.sh safety gates.
mk_gh_stub() { # mk_gh_stub <sandbox>
  mkdir -p "$1/bin"
  cat > "$1/bin/gh" <<'SH'
#!/usr/bin/env bash
[ -n "${GH_STUB_TOUCH:-}" ] && touch "$GH_STUB_TOUCH"                       # tree goes dirty
[ -n "${GH_STUB_COMMIT:-}" ] && git -C "$GH_STUB_COMMIT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m mid-query   # HEAD moves
[ -n "${GH_STUB_BRANCH:-}" ] && git -C "$GH_STUB_BRANCH" checkout -q -b switched-mid-query                                       # branch changes, same commit
want=""; prev=""
for a in "$@"; do [ "$prev" = "--base" ] && want=$a; prev=$a; done
[ -z "$want" ] || [ "$want" = "${GH_STUB_PR_BASE:-main}" ] || exit 0
for a in "$@"; do case $a in *"${GH_STUB_MERGED_SHA:-nope}"*) echo 7; exit 0;; esac; done
exit 0
SH
  chmod +x "$1/bin/gh"
}

# Sandbox: bare origin (with a corpus-shaped tree), an installed clone at
# $HOME/services/code-config (the $SVC trust anchor), and Hacking slots.
mk_sbx() { # mk_sbx <slot>... ; echoes sandbox dir
  local sbx; sbx=$(mktemp -d)
  mkdir -p "$sbx/Hacking" "$sbx/locks" "$sbx/services"
  git init -q --bare -b main "$sbx/origin.git"
  local seed="$sbx/seed"
  git clone -q "$sbx/origin.git" "$seed" 2>/dev/null  # silence empty-repo warning
  mkdir -p "$seed/claude"
  printf '# Rules\n\n## S\n\n- bullet one\n- bullet two\n- bullet three\n' > "$seed/claude/CLAUDE.md"
  printf '# Proposals\n\n## existing proposal\n**Change:** x\n' > "$seed/claude/PROPOSALS.md"
  git -C "$seed" add -A && commit "$seed" -m seed && git -C "$seed" push -q origin main
  git clone -q "$sbx/origin.git" "$sbx/services/code-config"
  cp -R "$HERE/../lib" "$sbx/services/code-config/lib"
  local d
  for d in "$@"; do
    git clone -q "$sbx/origin.git" "$sbx/Hacking/$d"
    git -C "$sbx/Hacking/$d" config user.email t@t
    git -C "$sbx/Hacking/$d" config user.name t
  done
  printf '%s\n' "$sbx"
}

# ---- claim-checkout.sh ------------------------------------------------------

# 1. claims the first free slot, pulls it, and HOLDS the lock (released in Step 6)
SBX=$(mk_sbx code-config0 code-config2)
# Advance origin so the claim has to actually fast-forward. _cc_accept compares
# HEAD to the remote-TRACKING ref right after `pull --ff-only origin main`, which
# only holds because git updates that ref when fetching a branch by name. No
# other test exercises the BEHIND-slot path, so without this the assumption is
# never exercised — and if it broke, every behind slot would be rejected and cleanup
# would clone a fresh one every run until the slots burn.
commit "$SBX/seed" --allow-empty -m "origin/main advances"
git -C "$SBX/seed" push -q origin main
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config0" "claim: picks first free slot"
assert_eq "$(git -C "$SBX/origin.git" rev-parse main)" "$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD)" "claim: a behind slot is fast-forwarded to origin/main"
assert_eq "yes" "$([ -d "$SBX/locks/tc-claim-code-config0" ] && echo yes)" "claim: lock still held after claim"
HOME="$SBX" bash "$SCRIPTS/release-claim.sh" "$SBX/locks/tc-claim-code-config0"
assert_eq "" "$([ -d "$SBX/locks/tc-claim-code-config0" ] && echo yes)" "release-claim: lock released"
rm -rf "$SBX"

# 2. skips a dirty slot and a wrong-origin slot; claims the next free one
# Slot 2 is ahead of origin: `pull --ff-only` succeeds trivially on a strictly-
# ahead branch, so it cannot stand in for "synced" — and cleanup's own
# commit-track-a.sh runs `git push origin main`, which would publish whatever
# unpushed commit was sitting there (§ Workspace Isolation's "commits you didn't
# write show up on main" tell).
SBX=$(mk_sbx code-config0 code-config1 code-config2 code-config3)
echo junk > "$SBX/Hacking/code-config0/dirty.txt"                  # dirty → skip
git -C "$SBX/Hacking/code-config1" remote set-url origin /nope.git # wrong origin → skip
commit "$SBX/Hacking/code-config2" --allow-empty -m "someone else's unpushed work"
ahead=$(git -C "$SBX/Hacking/code-config2" rev-parse HEAD)
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config3" "claim: skips dirty + wrong-origin + ahead-of-origin, picks next free"
assert_eq "$ahead" "$(git -C "$SBX/Hacking/code-config2" rev-parse HEAD)" "claim: the ahead commit is left unpublished"
rm -rf "$SBX"

# 2b. a cosmetically-different origin (trailing .git / slash) is the SAME remote → still claimed
SBX=$(mk_sbx code-config0)
git -C "$SBX/Hacking/code-config0" remote set-url origin "$SBX/origin.git/"  # cosmetic drift
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config0" "claim: cosmetic origin drift (.git/slash) still claimed"
rm -rf "$SBX"

# 3. exhaustion → auto-clones the lowest unused slot
SBX=$(mk_sbx code-config0)
git -C "$SBX/Hacking/code-config0" checkout -q -b feat/busy        # busy → not free
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config1" "claim: auto-clones lowest unused slot on exhaustion"
assert_eq "main" "$(git -C "$SBX/Hacking/code-config1" symbolic-ref --short HEAD)" "claim: auto-clone lands on main"
rm -rf "$SBX"

# 3b. a slot parked on a MERGED branch is RECLAIMED, not left to rot. This is the
# leak the pass exists for: nothing else returns a slot to main, so without it the
# fleet drains one slot per merged PR until every candidate is parked and cleanup
# can no longer write. Test 3 above is the fail-closed half — same parked shape,
# no gh confirmation, so it auto-clones instead of switching a branch it can't
# prove is merged.
SBX=$(mk_sbx code-config0)
git -C "$SBX/Hacking/code-config0" checkout -q -b feat/landed
commit "$SBX/Hacking/code-config0" --allow-empty -m landed
mk_gh_stub "$SBX"
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" PATH="$SBX/bin:$PATH" \
      GH_STUB_MERGED_SHA=$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD) \
      bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config0" "claim: reclaims a slot parked on a merged branch"
assert_eq "main" "$(git -C "$SBX/Hacking/code-config0" symbolic-ref --short HEAD)" "claim: reclaimed slot lands on main"
assert_eq "" "$([ -d "$SBX/Hacking/code-config1" ] && echo yes)" "claim: reclaim preempts the auto-clone"
rm -rf "$SBX"

# 3c. precedence: a FREE slot always wins over a reclaimable one, and the parked
# slot is left untouched. Without this, hoisting the reclaim pass above §1a would
# branch-switch an idle agent's checkout while a free slot sat unused, and 3b
# would still pass.
SBX=$(mk_sbx code-config0 code-config1)
git -C "$SBX/Hacking/code-config0" checkout -q -b feat/landed
commit "$SBX/Hacking/code-config0" --allow-empty -m landed
mk_gh_stub "$SBX"
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" PATH="$SBX/bin:$PATH" \
      GH_STUB_MERGED_SHA=$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD) \
      bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config1" "claim: a free slot outranks a reclaimable one"
assert_eq "feat/landed" "$(git -C "$SBX/Hacking/code-config0" symbolic-ref --short HEAD)" "claim: reclaimable slot left untouched while one is free"
# Prove slot0 was genuinely RECLAIMABLE, not merely skipped: without this the
# assertions above hold even if the merged-PR gate regressed to always-refuse,
# and 3c silently degenerates into a copy of test 2 (skip non-free, take next).
HOME="$SBX" bash "$SCRIPTS/release-claim.sh" "$SBX/locks/tc-claim-code-config1"
echo junk > "$SBX/Hacking/code-config1/dirty.txt"   # now nothing is free
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" PATH="$SBX/bin:$PATH" \
      GH_STUB_MERGED_SHA=$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD) \
      bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config0" "claim: same slot IS reclaimed once nothing is free"
assert_eq "main" "$(git -C "$SBX/Hacking/code-config0" symbolic-ref --short HEAD)" "claim: reclaimed slot lands on main"
rm -rf "$SBX"

# 3d. `master` and detached HEAD are NOT reclaimable. reseat.sh routes `master`
# down its default-branch path — pull, compare to origin/main — so without this
# skip cleanup pulls a branch it can never claim (_cc_free wants exactly `main`).
# Pinning it because reverting _cc_reclaimable's case arm to a bare `!= main`
# otherwise leaves the whole suite green.
SBX=$(mk_sbx code-config0 code-config1)
mk_gh_stub "$SBX"
git -C "$SBX/Hacking/code-config0" checkout -q -b master
git -C "$SBX/Hacking/code-config1" checkout -q --detach
# Make the mutation OBSERVABLE. A bare `checkout -b master` has no upstream, so
# reseat's `git pull --ff-only` fails and is swallowed by its `|| true` — the SHA
# would be unchanged whether or not master was skipped, and the assertion below
# would pin nothing. Give master an upstream and advance origin/main, so entering
# the pass fast-forwards it and the skip is the only thing that keeps it still.
git -C "$SBX/Hacking/code-config0" branch -q --set-upstream-to=origin/main master
commit "$SBX/seed" --allow-empty -m "origin/main moves"
git -C "$SBX/seed" push -q origin main
git -C "$SBX/Hacking/code-config0" fetch -q origin
before0=$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD)
before1=$(git -C "$SBX/Hacking/code-config1" rev-parse HEAD)
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" PATH="$SBX/bin:$PATH" \
      GH_STUB_MERGED_SHA=$before0 bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config2" "claim: master/detached are not reclaimable — auto-clones instead"
assert_eq "master" "$(git -C "$SBX/Hacking/code-config0" symbolic-ref --short HEAD)" "claim: master slot left on master"
assert_eq "$before0" "$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD)" "claim: master slot never pulled"
assert_eq "$before1" "$(git -C "$SBX/Hacking/code-config1" rev-parse HEAD)" "claim: detached-HEAD slot untouched"
rm -rf "$SBX"

# 3e. a stacked PR merged into its PARENT branch is merged, but its work is not
# in `main` — reseating that checkout would strand it, the orphaning failure
# `PR_LIFECYCLE.md` § Spec-doc PRs and stacking names. The query is pinned to
# `--base main`, so this reads as unmerged and the pass falls through to a clone.
SBX=$(mk_sbx code-config0)
mk_gh_stub "$SBX"
git -C "$SBX/Hacking/code-config0" checkout -q -b feat/stacked-child
commit "$SBX/Hacking/code-config0" --allow-empty -m "child work"
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" PATH="$SBX/bin:$PATH" \
      GH_STUB_MERGED_SHA=$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD) \
      GH_STUB_PR_BASE=feat/stacked-parent \
      bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config1" "claim: a PR merged into its parent (not main) is not reclaimable"
assert_eq "feat/stacked-child" "$(git -C "$SBX/Hacking/code-config0" symbolic-ref --short HEAD)" "claim: stacked-child slot left on its branch"
rm -rf "$SBX"

# 3f. the axis no reseat-level row can reach: the slot goes ineligible AFTER both
# of §1a2's own `_cc_reclaimable` checks have already passed — the pre-lock one
# and the under-lock one — which is precisely the window the claim lock does not
# close, since it excludes other CLAIMERS rather than an agent entering the
# checkout. End to end: reseat refuses, `_cc_accept` rejects, §1b clones instead.
# WHICH of the gate's three terms fired is pinned one row each in the reseat.sh
# section; this row is about WHEN.
SBX=$(mk_sbx code-config0)
mk_gh_stub "$SBX"
git -C "$SBX/Hacking/code-config0" checkout -q -b feat/landed
commit "$SBX/Hacking/code-config0" --allow-empty -m landed
out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" PATH="$SBX/bin:$PATH" \
      GH_STUB_MERGED_SHA=$(git -C "$SBX/Hacking/code-config0" rev-parse HEAD) \
      GH_STUB_BRANCH="$SBX/Hacking/code-config0" \
      bash "$SCRIPTS/claim-checkout.sh" 2>/dev/null | tail -2)
assert_contains "$out" "CONFIG_DIR=$SBX/Hacking/code-config1" "claim: a slot that left its branch mid-query is not reclaimed"
assert_eq "switched-mid-query" "$(git -C "$SBX/Hacking/code-config0" symbolic-ref --short HEAD)" "claim: the declined slot was not switched to main"
assert_eq "" "$(git -C "$SBX/Hacking/code-config0" status --porcelain)" "claim: the declined slot was left clean"
rm -rf "$SBX"

# 3g. the $SVC symbol preflight. The pick.sh half is the one with nothing else
# behind it — a missing claim_lock_path at least dies loudly mid-claim. An
# installed clone behind main carries a lib/ without the symbols this script
# sources, and each one fails differently: a missing _tcp_eligible makes _cc_free
# return 127 for EVERY candidate, so §1a skips all free slots and §1b clones a
# fresh one each run until they burn; a missing claim_lock_path breaks the claim
# itself, so no slot can be locked at all. The preflight turns either into "pull
# main in the installed clone". One row per PREFLIGHTED symbol, so dropping
# either term from the check fails its own row.
# Rows are read on fd 3 so the loop body's stdin is never this heredoc: a script
# under test that ever reads stdin would otherwise drain it and the remaining
# rows would silently not run, with the suite still green (assert_summary counts
# assertions run, not assertions expected).
preflight_out=
while IFS='|' read -r -u 3 libfile sym; do
  [ -n "$libfile" ] || continue
  SBX=$(mk_sbx code-config0)
  sed "/^$sym()/,/^}/d" "$SBX/services/code-config/$libfile" > "$SBX/lib.stripped" \
    && mv "$SBX/lib.stripped" "$SBX/services/code-config/$libfile"
  out=$(HOME="$SBX" TC_LOCK_DIR="$SBX/locks" bash "$SCRIPTS/claim-checkout.sh" 2>&1); rc=$?
  assert_eq "1" "$rc" "claim: installed clone missing $sym fails the preflight"
  assert_contains "$out" "pull --ff-only origin main" "claim: the $sym failure carries the remedy"
  [ -n "$preflight_out" ] || preflight_out=$out   # first row wins; the message is static
  rm -rf "$SBX"
done 3<<'ROWS'
lib/claim.sh|claim_lock_path
lib/pick.sh|_tcp_eligible
ROWS
# The FATAL string is static and names both symbols, so this is a one-off pin on
# the message — not a per-row discriminator, which is what it looked like inside
# the loop where it passed identically for either strip.
assert_contains "$preflight_out" "claim_lock_path/_tcp_eligible" "claim: the preflight FATAL names both preflighted symbols"

# ---- reseat.sh ---------------------------------------------------------------

SBX=$(mk_sbx code-config0)
D="$SBX/Hacking/code-config0"
assert_eq "n/a" "$(bash "$SCRIPTS/reseat.sh" "$SBX/Hacking")" "reseat: non-repo → n/a"
assert_eq "ready ✓ (on main)" "$(bash "$SCRIPTS/reseat.sh" "$D")" "reseat: on main + clean + synced → ready"
echo junk > "$D/dirty.txt"
assert_eq "not-free: uncommitted changes" "$(bash "$SCRIPTS/reseat.sh" "$D")" "reseat: dirty → not-free, untouched"
assert_eq "yes" "$([ -f "$D/dirty.txt" ] && echo yes)" "reseat: dirty file untouched"
rm "$D/dirty.txt"
# feature branch whose merge can't be confirmed (gh can't resolve a local bare
# origin) → not-free; uncertainty defaults to not-merged
git -C "$D" checkout -q -b feat/x
commit "$D" --allow-empty -m wip
assert_eq "not-free: unmerged branch feat/x" "$(bash "$SCRIPTS/reseat.sh" "$D")" "reseat: unconfirmable branch → not-free"
assert_eq "feat/x" "$(git -C "$D" symbolic-ref --short HEAD)" "reseat: branch left in place"
# merged-PR gate, all three directions, via a gh stub that mirrors real gh: it
# advertises merged PR #7 only when the caller's args pin the SHA in
# $GH_STUB_MERGED_SHA (so a reused branch name whose merged PR was for an OLDER
# head must NOT reseat) AND the requested --base matches the PR's own base,
# $GH_STUB_PR_BASE — which is how a stacked PR merged into its PARENT reads as
# not-in-main. An ABSENT --base is no filter at all, real gh semantics, and that
# is what makes the stacked case falsifiable: drop `--base main` from the query
# and the child matches again. The mutation knobs are documented on mk_gh_stub.
mk_gh_stub "$SBX"
assert_eq "not-free: unmerged branch feat/x" \
  "$(GH_STUB_MERGED_SHA=0000000000000000000000000000000000000000 PATH="$SBX/bin:$PATH" bash "$SCRIPTS/reseat.sh" "$D")" \
  "reseat: merged PR for a DIFFERENT head (reused branch name) → not-free"
assert_eq "ready ✓ (PR #7 merged → main)" \
  "$(GH_STUB_MERGED_SHA=$(git -C "$D" rev-parse HEAD) PATH="$SBX/bin:$PATH" bash "$SCRIPTS/reseat.sh" "$D")" \
  "reseat: merged branch (gh-confirmed exact HEAD) → switched to main"
assert_eq "main" "$(git -C "$D" symbolic-ref --short HEAD)" "reseat: merged branch reseated onto main"
# A stacked PR merged into its PARENT is merged, but its work is NOT in main —
# reseating that checkout strands exactly what PR_LIFECYCLE.md § Spec-doc PRs
# and stacking warns about. The query is pinned to --base main, so this reads as
# unmerged; drop that pin and the child matches again.
git -C "$D" checkout -q -b feat/stacked-child
commit "$D" --allow-empty -m child-work
assert_eq "not-free: unmerged branch feat/stacked-child" \
  "$(GH_STUB_MERGED_SHA=$(git -C "$D" rev-parse HEAD) GH_STUB_PR_BASE=feat/stacked-parent \
     PATH="$SBX/bin:$PATH" bash "$SCRIPTS/reseat.sh" "$D")" \
  "reseat: PR merged into its PARENT, not main → not-free"
assert_eq "feat/stacked-child" "$(git -C "$D" symbolic-ref --short HEAD)" "reseat: stacked child left on its branch"
# Every input the merged-PR match rests on can go stale during the seconds-long
# gh call, and the pre-switch re-check has to see all three — one row per input.
# The stub dirties the tree; commits (HEAD moves, tree clean); or checks out a
# new branch at the SAME commit, where the tree and HEAD are both unchanged and
# only $br sees it — and that branch is exactly what `checkout main` would yank
# away. Each row fails alone when its own term is removed from the gate.
# The third column plus the HEAD pin are what make each row prove its OWN term
# fired: every row asserts the state of all three inputs, so exactly one has
# moved. The clean column is total — a row that claims a dirty tree asserts it
# went dirty, and a malformed value fails rather than skipping — and HEAD is
# pinned on every row but COMMIT, whose whole point is that HEAD moved.
while IFS='|' read -r -u 3 knob want clean; do
  [ -n "$knob" ] || continue
  git -C "$D" checkout -q feat/stacked-child
  git -C "$D" branch -q -D switched-mid-query 2>/dev/null
  rm -f "$D/dirtied-mid-query.txt"
  val=$D
  [ "$knob" = GH_STUB_TOUCH ] && val="$D/dirtied-mid-query.txt"
  before_sha=$(git -C "$D" rev-parse HEAD)
  assert_eq "not-free: became ineligible during the merge check" \
    "$(env "$knob=$val" GH_STUB_MERGED_SHA="$before_sha" \
       PATH="$SBX/bin:$PATH" bash "$SCRIPTS/reseat.sh" "$D")" \
    "reseat: $knob during the merge query → not switched"
  assert_eq "$want" "$(git -C "$D" symbolic-ref --short HEAD)" "reseat: $knob left the checkout on $want"
  case $clean in
    yes) assert_eq "" "$(git -C "$D" status --porcelain)" \
           "reseat: $knob kept a clean tree, so the tree term is not what fired" ;;
    no)  assert_eq "?? dirtied-mid-query.txt" "$(git -C "$D" status --porcelain)" \
           "reseat: $knob did dirty the tree, so the row exercises what it claims" ;;
    *)   assert_eq "yes|no" "$clean" "reseat: row $knob has a malformed clean column" ;;
  esac
  [ "$knob" != GH_STUB_COMMIT ] && assert_eq "$before_sha" "$(git -C "$D" rev-parse HEAD)" \
    "reseat: $knob kept HEAD, so the SHA term is not what fired"
done 3<<'ROWS'
GH_STUB_TOUCH|feat/stacked-child|no
GH_STUB_COMMIT|feat/stacked-child|yes
GH_STUB_BRANCH|switched-mid-query|yes
ROWS
# The fourth input to that gate is the caller's own: the tmux half of "idle"
# needs lib/pick.sh, and Step 6 reseats the session's OWN checkout where a live
# pane is expected, so it rides in as $2 instead of living in reseat. Both
# directions, or a guard wired to always reject would pass.
git -C "$D" checkout -q feat/stacked-child
guard_sha=$(git -C "$D" rev-parse HEAD)
assert_eq "not-free: became ineligible during the merge check" \
  "$( . "$SCRIPTS/reseat.sh"; _busy() { return 1; }
      GH_STUB_MERGED_SHA=$guard_sha PATH="$SBX/bin:$PATH" reseat_if_ready "$D" _busy )" \
  "reseat: a pre-switch guard that rejects blocks the switch"
assert_eq "feat/stacked-child" "$(git -C "$D" symbolic-ref --short HEAD)" \
  "reseat: the rejected checkout is left on its branch, not switched"
assert_eq "ready ✓ (PR #7 merged → main)" \
  "$( . "$SCRIPTS/reseat.sh"; _idle() { return 0; }
      GH_STUB_MERGED_SHA=$guard_sha PATH="$SBX/bin:$PATH" reseat_if_ready "$D" _idle )" \
  "reseat: a guard that accepts leaves the merged-PR switch intact"
# on main but ahead of origin → error, left as-is
git -C "$D" checkout -q main
commit "$D" --allow-empty -m local-only
assert_eq "error: HEAD != origin/main" "$(bash "$SCRIPTS/reseat.sh" "$D")" "reseat: local-ahead main → error, left as-is"
rm -rf "$SBX"

# ---- stash-untracked.sh ------------------------------------------------------

# untracked-only → stashed (rel-paths preserved) + reseat re-called
SBX=$(mk_sbx code-config0)
D="$SBX/Hacking/code-config0"
mkdir -p "$D/sub"
echo a > "$D/junk.txt"; echo b > "$D/sub/junk.txt"
out=$(bash "$SCRIPTS/stash-untracked.sh" "$D")
stash=$(sed -n 's/^Step 6a stash: //p' <<<"$out")
assert_contains "$out" "ready ✓ (on main)" "stash: reseat re-called after stash"
assert_eq "yes" "$([ -f "$stash/junk.txt" ] && [ -f "$stash/sub/junk.txt" ] && echo yes)" "stash: rel-paths preserved in stash"
assert_eq "" "$(git -C "$D" status --porcelain)" "stash: checkout left clean"
# tracked modification → abort untouched (the untracked-only contract)
echo changed >> "$D/claude/CLAUDE.md"
echo junk > "$D/junk2.txt"
rc=0; out=$(bash "$SCRIPTS/stash-untracked.sh" "$D" 2>&1) || rc=$?
assert_rc 1 "$rc" "stash: tracked modification → abort rc 1"
assert_contains "$out" "Step 6a aborted" "stash: abort is loud"
assert_eq "yes" "$([ -f "$D/junk2.txt" ] && echo yes)" "stash: nothing moved on abort"
rm -rf "$SBX"
# unmerged feature branch + untracked dirt → dirt stashed, branch left alone
SBX=$(mk_sbx code-config0); D="$SBX/Hacking/code-config0"
git -C "$D" checkout -q -b feat/wip; commit "$D" --allow-empty -m wip
echo junk > "$D/junk.txt"
out=$(bash "$SCRIPTS/stash-untracked.sh" "$D")
assert_contains "$out" "not-free: unmerged branch feat/wip" "stash: unmerged branch never switched (merged-HEAD gate)"
assert_eq "" "$(git -C "$D" status --porcelain)" "stash: untracked dirt cleared even when branch stays"
rm -rf "$SBX"

# ---- teardown-dev-stack.sh (pure derivations; docker/Lima can't run here) -----

. "$SCRIPTS/teardown-dev-stack.sh"   # BASH_SOURCE guard: definitions only
SBX=$(mktemp -d)
printf 'PLOW_VARIANT=wt3\n' > "$SBX/.env.local"
assert_eq "wt3" "$(td_variant "$SBX")" "teardown: PLOW_VARIANT parsed from .env.local"
rm "$SBX/.env.local"
assert_eq "" "$(td_variant "$SBX")" "teardown: no .env.local → bare variant (and no abort)"
assert_eq "/Users/t/Library/Application Support/co.plow.app.dev/lima" \
  "$(td_lima_home '123 limactl hostagent --pidfile /Users/t/Library/Application Support/co.plow.app.dev/lima/plow-runtime/ha.pid plow-runtime')" \
  "teardown: LIMA_HOME survives spaces in the path (macOS Application Support)"
assert_eq "/Users/t/.lima" \
  "$(td_lima_home '123 limactl hostagent --pidfile /Users/t/.lima/plow-runtime/ha.pid plow-runtime')" \
  "teardown: LIMA_HOME extracted from a space-free path"
rm -rf "$SBX"

# ---- commit-track-a.sh -------------------------------------------------------

# happy path: garden edit lands on origin/main
SBX=$(mk_sbx code-config0); D="$SBX/Hacking/code-config0"
printf '# Rules\n\n## S\n\n- bullet two\n- bullet one\n- bullet three\n' > "$D/claude/CLAUDE.md"
out=$(bash "$SCRIPTS/commit-track-a.sh" "$D" claude/CLAUDE.md 2>/dev/null)
assert_contains "$out" "track-a: committed" "track-a: happy path commits"
assert_contains "$(git -C "$SBX/origin.git" log -1 --format=%s main)" "garden cited rules and skills" "track-a: garden edit pushed to origin/main"
# genuine overlap → THIS run's garden edit dropped, tree back at origin/main
git clone -q "$SBX/origin.git" "$SBX/other"
printf '# Rules\n\n## S\n\n- bullet three\n- bullet one\n- bullet two\n' > "$SBX/other/claude/CLAUDE.md"
commit "$SBX/other" -am other-reorder && git -C "$SBX/other" push -q origin main
printf '# Rules\n\n## S\n\n- bullet one\n- bullet two\n- bullet three\n' > "$D/claude/CLAUDE.md"
out=$(bash "$SCRIPTS/commit-track-a.sh" "$D" claude/CLAUDE.md 2>/dev/null)
assert_contains "$out" "dropped on conflict" "track-a: conflicting garden edit dropped (recurs next session)"
assert_eq "$(git -C "$D" rev-parse origin/main)" "$(git -C "$D" rev-parse HEAD)" "track-a: checkout reset to origin/main after drop"
assert_eq "" "$(git -C "$D" status --porcelain)" "track-a: clean tree after drop"
rm -rf "$SBX"

# ---- commit-track-b.sh -------------------------------------------------------

# happy path: append lands; rc 0 (the mark-promoted gate)
SBX=$(mk_sbx code-config0); D="$SBX/Hacking/code-config0"
printf '\n## new proposal\n**Change:** y\n' >> "$D/claude/PROPOSALS.md"
rc=0; out=$(bash "$SCRIPTS/commit-track-b.sh" "$D" 2>/dev/null) || rc=$?
assert_rc 0 "$rc" "track-b: happy path rc 0"
assert_contains "$(git -C "$SBX/origin.git" log -1 --format=%s main)" "record proposal" "track-b: append pushed to origin/main"
# rebase-retry: a non-conflicting concurrent push is absorbed, not surfaced
git clone -q "$SBX/origin.git" "$SBX/other2"
echo '- unrelated' >> "$SBX/other2/claude/CLAUDE.md"
commit "$SBX/other2" -am unrelated && git -C "$SBX/other2" push -q origin main
printf '\n## second proposal\n**Change:** z\n' >> "$D/claude/PROPOSALS.md"
rc=0; bash "$SCRIPTS/commit-track-b.sh" "$D" >/dev/null 2>&1 || rc=$?
assert_rc 0 "$rc" "track-b: rebase-retry absorbs a non-conflicting concurrent push"
# secret shape in PROPOSALS.md → abort BEFORE git add, rc 1, nothing staged
printf '\n## oops\n**Change:** key is sk-AAAAAAAAAAAAAAAAAAAAAAAAAxyz\n' >> "$D/claude/PROPOSALS.md"
before=$(git -C "$D" rev-parse HEAD)
rc=0; out=$(bash "$SCRIPTS/commit-track-b.sh" "$D" 2>&1) || rc=$?
assert_rc 1 "$rc" "track-b: secret shape → rc 1"
assert_contains "$out" "Aborting before git add" "track-b: secret abort happens before staging"
assert_eq "$before" "$(git -C "$D" rev-parse HEAD)" "track-b: no commit made on secret abort"
assert_eq "" "$(git -C "$D" diff --cached --name-only)" "track-b: nothing staged on secret abort"
git -C "$D" checkout -q -- claude/PROPOSALS.md
# conflict (same region) → rc 1, commit PARKED on an origin branch, main back on origin/main
git clone -q "$SBX/origin.git" "$SBX/other3"
printf '\n## colliding A\n' >> "$SBX/other3/claude/PROPOSALS.md"
commit "$SBX/other3" -am collide && git -C "$SBX/other3" push -q origin main
printf '\n## colliding B\n' >> "$D/claude/PROPOSALS.md"
rc=0; out=$(bash "$SCRIPTS/commit-track-b.sh" "$D" 2>&1) || rc=$?
assert_rc 1 "$rc" "track-b: conflict → rc 1 (memories NOT marked)"
park=$(git -C "$SBX/origin.git" for-each-ref --format='%(refname:short)' refs/heads/cleanup/)
assert_contains "$(git -C "$SBX/origin.git" show "$park:claude/PROPOSALS.md" 2>&1)" "## colliding B" "track-b: conflicting proposal parked on origin"
assert_contains "$out" "$park" "track-b: conflict names the parked branch"
assert_eq "$(git -C "$D" rev-parse origin/main)" "$(git -C "$D" rev-parse HEAD)" "track-b: main back on origin/main (later pull --ff-only works)"
assert_eq "" "$(git -C "$D" status --porcelain)" "track-b: clean tree after parking"
# push can't land (origin unreachable) → rc 1, SURFACES, commit preserved locally, clean tree
git -C "$D" remote set-url origin "$SBX/gone.git"
printf '\n## stranded\n' >> "$D/claude/PROPOSALS.md"
rc=0; out=$(bash "$SCRIPTS/commit-track-b.sh" "$D" 2>&1) || rc=$?
assert_rc 1 "$rc" "track-b: unlandable push → rc 1 (memories NOT marked)"
assert_contains "$out" "recover with" "track-b: unlandable push surfaces a recovery command"
assert_contains "$(git -C "$D" log -1 --format=%s)" "record proposal" "track-b: proposal commit preserved locally"
assert_eq "" "$(git -C "$D" status --porcelain)" "track-b: clean tree after a failed push"
rm -rf "$SBX"

assert_summary
