#!/usr/bin/env bash
# teardown-dev-stack.sh — /cleanup §6b: spin down a leftover dev stack in the
# CALLER's checkout (the API compose stack + the launched Mac app's Lima runtime
# VM — the multi-GiB RAM consumer that defeats Step 6's "leave the host idle").
# Runs regardless of the caller's branch/reseat state — the stack is usually up
# precisely mid-test on an unmerged branch, exactly when reclaiming RAM matters.
#
# RECIPE-FREE teardown — the security boundary: never the caller's `just`
# recipes, never a checkout-built or checkout-PATH-resolved binary (a §6b that
# ran `just app down` from an unmerged caller branch would execute potentially
# PR-controlled recipe code). Operate on already-running docker/Lima state only.
#
# Scope — the caller's own variant ONLY, never a parallel session's stack.
# Variant-scoping alone is NOT sufficient: with PLOW_VARIANT unset (the common
# case) every checkout's dev stack resolves to the same bare `plow` project, so
# a label match can land on a SIBLING checkout's stack (observed reap of
# ~/Hacking/plow5's). The config_files-under-$CALLER_REPO ownership guard below
# — not variant-scoping — is what guarantees a sibling's stack is never touched.
# Teardown-only, dev-variant only (never prod co.plow.app), best-effort.
#
# Output (stdout, final line): `dev stack: <spun down|none running|teardown errored>`
# Pure text derivations, factored out so they're unit-testable without docker/Lima
# (tests/test-cleanup-scripts.sh sources this file; the BASH_SOURCE guard below
# keeps the procedural body from running — and the `set` stays below the guard
# so sourcing is side-effect-free for the harness's shell options).
td_variant() { # td_variant <caller-repo> — PLOW_VARIANT from .env.local, "" when unset
  # `|| true`: no .env.local / no PLOW_VARIANT must not abort.
  grep -E '^PLOW_VARIANT=' "$1/.env.local" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true
}
td_lima_home() { # td_lima_home <hostagent-cmdline> — LIMA_HOME from the --pidfile arg
  # Greedy capture anchored on the fixed /plow-runtime/ha.pid suffix — a stingy
  # ([^ ]*) would truncate at spaces, and macOS data dirs routinely contain them
  # (~/Library/Application Support/…), yielding a wrong/partial LIMA_HOME.
  sed -nE 's#.*--pidfile (.*)/plow-runtime/ha\.pid.*#\1#p' <<<"$1"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0   # sourced for tests — definitions only

set -uo pipefail   # best-effort: no -e — a half-up stack is non-fatal, log + continue
CALLER_REPO=${1:?usage: teardown-dev-stack.sh <caller-checkout>}
variant=$(td_variant "$CALLER_REPO")
proj="plow${variant:+-$variant}"               # this checkout's compose project (bare `plow` when unset)
bundle="co.plow.app.dev${variant:+.$variant}"  # this checkout's dev bundle — NEVER prod co.plow.app

matched=0 errored=0

# 1. Containers — bring down THIS checkout's compose project by label. Both
# steps match $proj/$bundle exactly — never an enumerate-all-dev-stacks sweep.
cid=$(docker ps -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null | head -1 || true)
if [ -n "$cid" ]; then
  # Ownership guard: confirm the matched stack's compose files live under
  # $CALLER_REPO before `down`; skip+report otherwise. config_files is
  # comma-joined under an override stack, but all entries share the project
  # dir, so a prefix check settles ownership. It is read ONLY for this string
  # compare — never fed to `-f` (docker compose rejects the joined value).
  cfg=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
  case "$cfg" in
    "$CALLER_REPO"/*) matched=1; docker compose -p "$proj" down --remove-orphans || errored=1 ;;
    *) echo "dev stack: skipped (project '$proj' owned by another checkout: ${cfg%%,*})" ;;
  esac
fi

# 2. Dev Lima VM — stop THIS checkout's runtime VM. DISCOVER the dev VM's
# LIMA_HOME from the matching hostagent (read-only: the pidfile under this exact
# $bundle — fixed-string /$bundle/lima/ so co.plow.app.dev can't prefix-match
# co.plow.app.dev.wt3, and prod co.plow.app/ is excluded), but EXECUTE only the
# fixed prod-app-bundle limactl (install-managed/signed) — never a PATH-resolved
# binary (the caller's ambient PATH is checkout-influenceable) or the dev-app's
# own bundled binary (built from the possibly-unmerged caller branch).
ha=$(pgrep -fl 'limactl hostagent' | grep -F "/$bundle/lima/" | head -1 || true)
if [ -n "$ha" ]; then
  home=$(td_lima_home "$ha")
  limactl=/Applications/Plow.app/Contents/Resources/bin/limactl   # fixed trusted path ONLY — no PATH/dev-app fallback
  if [ -n "$home" ] && [ -x "$limactl" ]; then
    matched=1
    LIMA_HOME="$home" "$limactl" stop -f plow-runtime || errored=1
  else
    echo "no trusted prod-bundle limactl — leaving dev VM; stop manually or reseat+rerun"
  fi
fi

if [ "$errored" -ne 0 ]; then echo "dev stack: teardown errored"
elif [ "$matched" -ne 0 ]; then echo "dev stack: spun down"
else echo "dev stack: none running"
fi
