#!/bin/sh
# Measure actual writes to the reintroduced member, not just sync percentage.
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
helper=$2
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
mdadm --readwrite "$md"
dd if=/dev/urandom of="$md" bs=1M count=1 seek=8 conv=fsync status=none
payload=$(dd if="$md" bs=1M count=16 status=none | sha256sum)
for attempt in $(seq 1 50); do
    [ "$(cat "$kernel/array_state")" = clean ] && break
    sleep 0.2
done
[ "$(cat "$kernel/array_state")" = clean ]
before=$(awk '{ print $7 }' "/sys/class/block/${former##*/}/stat")
mdadm --examine --export "$former"
mdadm --examine --export "$survivor"
component=$(cat "$kernel/component_size")
mdraid_transition re-add-member "$former" "$slot"
mdadm --wait "$md" || [ "$(cat "$kernel/sync_action")" = idle ]
after=$(awk '{ print $7 }' "/sys/class/block/${former##*/}/stat")
sectors=$((after - before))
[ "$sectors" -gt 0 ]
[ "$(cat "$kernel/dev-${former##*/}/slot")" = "$slot" ]
grep -qw in_sync "$kernel/dev-${former##*/}/state"
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(dd if="$md" bs=1M count=16 status=none | sha256sum)" = "$payload" ]
if [ "$sectors" -lt "$((component * 2))" ]; then
    printf 'MEASURED: bitmap re-add wrote %s sectors; component %s sectors (partial member writes, including metadata)\n' "$sectors" "$((component * 2))"
else
    printf 'MEASURED: full rebuild or greater member writes: %s sectors; component %s sectors\n' "$sectors" "$((component * 2))"
fi
