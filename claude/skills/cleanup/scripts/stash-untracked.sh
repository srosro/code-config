#!/usr/bin/env bash
# stash-untracked.sh — /cleanup §6a: untracked-only stash-and-reseat escape hatch.
# Caller checkout ONLY (never $CONFIG_DIR, never Step 1's candidate loop — that
# path wants strict skip-it semantics on dirty state). Apply only when the reseat
# said `not-free: uncommitted changes` and the dirt looks untracked-only — this
# script re-verifies that gate itself and aborts on any tracked modification.
#
# Untracked-only dirt (build artifacts, dev-env files, pytest mock leakage,
# orphaned screenshots) is recoverable junk, never in-progress work; it moves to
# a mode-700 /tmp stash, then the reseat routine is RE-CALLED — never a raw
# `checkout -f main`, whose missing merged-HEAD gate would silently lose an
# unmerged feature-branch HEAD. The stash is never auto-deleted (/tmp cleanup is
# the OS's job); the caller surfaces the printed stash path in its report.
set -euo pipefail
DIR=${1:?usage: stash-untracked.sh <caller-checkout>}

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/reseat.sh"   # reseat_if_ready (BASH_SOURCE guard keeps it from auto-running)

# Single status snapshot: preflight AND collect paths in one pass. Reading
# `git status -z --porcelain` a second time for the move loop opens a TOCTOU
# window — a tracked file becoming dirty between the two reads would get moved
# into /tmp despite the untracked-only contract. `-z` (NUL-delimited, no
# quoting) is safe against newlines / quotes / metacharacters in path names
# that the text porcelain form would quote-wrap.
paths=()
while IFS= read -r -d '' entry; do
  [ "${entry:0:2}" = "??" ] || { echo "FATAL: Step 6a aborted — non-untracked dirty entry detected ('${entry:0:2}'); modified-tracked content is real work, leaving \$DIR alone"; exit 1; }
  paths+=("${entry:3}")  # strip "XY " (status code + space)
done < <(git -C "$DIR" status -z --porcelain)
[ "${#paths[@]}" -gt 0 ] || { echo "nothing to stash — tree is clean"; reseat_if_ready "$DIR"; exit 0; }

# Mode-700 stash dir — token-bearing files (.env, .plow-dev-env, credentials)
# are explicitly stashable, so the dir MUST NOT be world-readable. `mktemp -d`
# is mode 700 on macOS/Linux; the suffix template makes the path self-describing.
STASH=$(mktemp -d "/tmp/$(basename "$DIR")-stash-$(date +%Y%m%d-%H%M%S).XXXXXX")
chmod 700 "$STASH"  # defense-in-depth: BSD mktemp creates 700; explicit anyway
# Surface the stash path BEFORE the first `mv` — if a volatile artifact
# disappears or `mv` fails partway, `set -euo pipefail` aborts; without this
# early print the recovery path would never reach the readiness report.
echo "Step 6a stash: $STASH"

# Move each untracked entry. Per § Secrets: never cat/inspect contents — an
# untracked .env / credentials file may be token-bearing; move by name only.
# Plain `mv` (NOT `mv -v`): filenames themselves can be secret-bearing, so
# don't echo paths into the transcript. Preserve relative paths so two
# same-named files in different dirs don't collide on a flat mv.
for path in "${paths[@]}"; do
  mkdir -p "$STASH/$(dirname "$path")"
  mv "$DIR/$path" "$STASH/$(dirname "$path")/"
done

# Re-call the reseat routine — its merged-HEAD gate is what prevents losing an
# unmerged feature-branch HEAD. The stash cleared untracked dirt, but the
# branch state is still real: an unmerged branch stays put (`not-free: …`).
reseat_if_ready "$DIR"
