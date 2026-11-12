#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
helper=$2
if [ "${3:-}" = readd ]; then
    mdraid_setup 1 2 0
    mdraid_call bitmap-enable - 0
    former=$(mdraid_loop 0)
    survivor=$(mdraid_loop 1)
    slot=$(cat "$kernel/dev-${former##*/}/slot")
    mdadm --stop "$md"
    md=
    mdadm --assemble --run "/dev/md/$name" "$survivor"
    md=$(readlink -f "/dev/md/$name")
    kernel="/sys/class/block/${md##*/}/md"
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    # Switch this explicitly owned fixture out of mdadm's auto-read-only state.
    mdraid_require_writable
    for delay in 1 2 3 4 5; do
        [ "$(cat "$kernel/array_state")" = clean ] && break
        sleep 1
    done
    [ "$(cat "$kernel/degraded")" = 1 ]
    mdraid_transition re-add-member "$former" "$slot"
    mdadm --wait "$md" || [ "$(cat "$kernel/sync_action")" = idle ]
    [ "$(cat "$kernel/degraded")" = 0 ]
    [ "$(cat "$kernel/dev-${former##*/}/slot")" = "$slot" ]
    grep -qw in_sync "$kernel/dev-${former##*/}/state"
    [ "$(mdraid_checksum)" = "$checksum" ]
    exit 0
fi
mdraid_setup 1 2 1
spare=$(mdraid_loop 2)
mdraid_call add-spare "$spare" 0
[ "$(cat "$kernel/dev-${spare##*/}/slot")" = none ]
mdraid_call remove-spare "$spare" 0
[ ! -e "$kernel/dev-${spare##*/}" ]
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(mdraid_checksum)" = "$checksum" ]
member=$(mdraid_loop 0)
member_slot=$(cat "$kernel/dev-${member##*/}/slot")
result=0
mdraid_transition mark-faulty "$member" "$((1 - member_slot))" || result=$?
[ "$result" = 2 ]
[ "$(cat "$kernel/degraded")" = 0 ]
mdraid_transition mark-faulty "$member" "$member_slot"
[ "$(cat "$kernel/degraded")" = 1 ]
grep -qw faulty "$kernel/dev-${member##*/}/state"
[ "$(mdraid_checksum)" = "$checksum" ]
