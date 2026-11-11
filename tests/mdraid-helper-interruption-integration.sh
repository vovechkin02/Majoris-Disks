#!/bin/sh
# This exercises service result classification, not a desktop Polkit agent.
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
faults=$(realpath "$2")
mdraid_setup 1 2 0
member=$(mdraid_loop 0)
for mode in before cancel deny unknown kill-before kill-after; do
    mdraid_refresh
    MAJORIS_MDRAID_HELPER_FAULT=$mode LD_PRELOAD="$faults" \
        "$service" expect-helper-failure "$fixture" "$array_uuid" "$md" "$member" 0
    if [ "$mode" = kill-after ]; then
        [ "$(cat "$kernel/degraded")" = 1 ]
        grep -qw faulty "$kernel/dev-${member##*/}/state"
    else
        [ "$(cat "$kernel/degraded")" = 0 ]
        grep -qw in_sync "$kernel/dev-${member##*/}/state"
    fi
    [ "$(mdraid_checksum)" = "$checksum" ]
done
