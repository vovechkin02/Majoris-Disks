#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
MAJORIS_MDRAID_CHURN_SCRIPT=$(realpath "$(dirname "$0")/mdraid-target-churn.sh")
export MAJORIS_MDRAID_CHURN_SCRIPT
mdraid_setup 1 2 1
missing=$(mdraid_loop 0)
target=$(mdraid_loop 2)
mdadm --manage "$md" --fail "$missing" --remove "$missing"
mdraid_call "reject-target-$2" "$target" 1
[ "$(cat "$kernel/degraded")" = 1 ]
[ ! -e "$kernel/dev-${target##*/}" ]
[ "$(mdraid_checksum)" = "$checksum" ]
