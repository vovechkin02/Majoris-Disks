#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
mdraid_setup 1 2 0
printf '1024\n' > "$kernel/sync_speed_min"
printf '4096\n' > "$kernel/sync_speed_max"
mdraid_call check-cancel - 0
[ "$(cat "$kernel/sync_action")" = idle ]
[ "$(cat "$kernel/last_sync_action")" = check ]
left=$(mdraid_loop 0)
right=$(mdraid_loop 1)
offset=$(cat "$kernel/dev-${right##*/}/offset")
[ "$((offset % 8))" = 0 ]
mdadm --stop "$md"
md=
mdraid_owned_loop "$left" "$fixture/member-0.img"
mdraid_owned_loop "$right" "$fixture/member-1.img"
# Introduce one mismatch beyond the payload checksum region on the offline fixture.
dd if=/dev/urandom of="$right" bs=4096 count=1 seek="$((offset / 8 + 2048))" oflag=direct conv=fsync status=none
mdadm --assemble --run "/dev/md/$name" "$left" "$right"
md=$(readlink -f "/dev/md/$name")
kernel="/sys/class/block/${md##*/}/md"
[ "$(mdraid_uuid "$md")" = "$array_uuid" ]
mdadm --readwrite "$md"
printf '1024\n' > "$kernel/sync_speed_min"
printf '8192\n' > "$kernel/sync_speed_max"
mdraid_call check - 0
[ "$(cat "$kernel/sync_action")" = idle ]
[ "$(cat "$kernel/last_sync_action")" = check ]
[ "$(cat "$kernel/mismatch_cnt")" -gt 0 ]
mdraid_call repair - 0
[ "$(cat "$kernel/sync_action")" = idle ]
[ "$(cat "$kernel/last_sync_action")" = repair ]
mdraid_call check - 0
[ "$(cat "$kernel/mismatch_cnt")" = 0 ]
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(mdraid_checksum)" = "$checksum" ]
