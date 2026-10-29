#!/usr/bin/env bash
# release-claim.sh — release the Step-1 slot claim taken by claim-checkout.sh.
# Run AFTER the $CONFIG_DIR reseat (the claim is held through the final git
# writes so concurrent runs can't collide). A crashed run that never reaches
# this self-heals via lib/claim.sh's 4h staleness reclaim.
set -euo pipefail
CLAIM_LOCK=${1:?usage: release-claim.sh <lock-path>}
SVC=~/services/code-config
. "$SVC/lib/claim.sh"
release_slot "$CLAIM_LOCK"
