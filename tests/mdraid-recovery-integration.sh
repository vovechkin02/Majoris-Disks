#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
case "$2" in
    raid1) count=2; level=1; losses=1 ;;
    raid5) count=3; level=5; losses=1 ;;
    raid6) count=4; level=6; losses=1 ;;
    raid6-double) count=4; level=6; losses=2 ;;
    raid10) count=4; level=10; losses=1 ;;
    start-raid1) count=2; level=1; losses=1 ;;
    start-raid5) count=3; level=5; losses=1 ;;
    dirty-raid5) count=3; level=5; losses=1 ;;
    restart-raid1) count=2; level=1; losses=1 ;;
    *) exit 2 ;;
esac
mdraid_setup "$level" "$count" "$losses"
case "$2" in
    start-*)
        missing=$(mdraid_loop 0)
        survivor=$(mdraid_loop 1)
        mdadm --stop "$md"
        md=
        mdraid_detach_member "$missing"
        mdraid_refresh_loops
        "$service" start-degraded "$fixture" "$array_uuid" "$survivor" - 1
        for candidate in /sys/class/block/md*/md/uuid; do
            [ -r "$candidate" ] &&
                [ "$(tr -d '-' < "$candidate")" = "$(printf '%s' "$array_uuid" | tr -d ':')" ] || continue
            kernel=${candidate%/uuid}
            disk=${kernel%/md}
            md="/dev/${disk##*/}"
        done
        [ -n "$md" ] && [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
        [ "$(cat "$kernel/degraded")" = 1 ]
        [ "$(mdraid_checksum)" = "$checksum" ]
        exit 0 ;;
esac
if [ "$2" = dirty-raid5 ]; then
    printf '0\n' > "$kernel/safe_mode_delay"
    dd if=/dev/zero of="$md" bs=1M count=1 seek=8 conv=fsync status=none
    [ "$(cat "$kernel/array_state")" = active ]
fi
i=0
while [ "$i" -lt "$losses" ]; do
    loop=$(mdraid_loop "$i")
    mdraid_owned_loop "$loop" "$fixture/member-$i.img"
    mdadm --manage "$md" --fail "$loop" --remove "$loop"
    i=$((i + 1))
done
if [ "$2" = dirty-raid5 ]; then
    [ "$(cat "$kernel/array_state")" = active ]
    mdraid_call refuse - 1
    [ "$(cat "$kernel/degraded")" = 1 ]
    [ "$(mdraid_checksum)" = "$checksum" ]
    exit 0
fi
if [ "$2" = restart-raid1 ]; then
    printf '1024\n' > "$kernel/sync_speed_min"
    printf '2048\n' > "$kernel/sync_speed_max"
    replacement=$(mdraid_loop "$count")
    # exec makes the recorded child PID the Majoris service test process.
    mdraid_refresh
    (
        exec "$service" replace "$fixture" "$array_uuid" "$md" "$replacement" 1
    ) > "$fixture/initiator.log" 2>&1 &
    initiator=$!
    for n in $(seq 1 100); do
        [ "$(cat "$kernel/sync_action")" = recover ] && break
        if ! kill -0 "$initiator" 2>/dev/null; then cat "$fixture/initiator.log"; exit 1; fi
        sleep 0.2
    done
    [ "$(cat "$kernel/sync_action")" = recover ]
    kill "$initiator"
    wait "$initiator" || true
    initiator=
    "$service" observe "$fixture" "$array_uuid" "$md" "$replacement" 1 > "$fixture/observer.log" 2>&1 &
    observer=$!
    for n in $(seq 1 50); do
        grep -q '^rebuild-observed$' "$fixture/observer.log" && break
        if ! kill -0 "$observer" 2>/dev/null; then cat "$fixture/observer.log"; exit 1; fi
        sleep 0.2
    done
    grep -q '^rebuild-observed$' "$fixture/observer.log"
    systemctl restart udisks2
    result=0
    wait "$observer" || result=$?
    observer=
    cat "$fixture/observer.log"
    [ "$result" = 0 ]
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    [ "$(cat "$kernel/degraded")" = 0 ]
    [ "$(mdraid_checksum)" = "$checksum" ]
    exit 0
fi
remaining=$losses
i=0
while [ "$i" -lt "$losses" ]; do
    replacement=$(mdraid_loop "$((count + i))")
    mdraid_call reject-stale-review "$replacement" "$remaining"
    [ ! -e "$kernel/dev-${replacement##*/}" ]
    mdraid_call replace "$replacement" "$remaining"
    remaining=$((remaining - 1))
    [ "$(cat "$kernel/degraded")" = "$remaining" ]
    [ "$(cat "$kernel/sync_action")" = idle ]
    slot=$(cat "$kernel/dev-${replacement##*/}/slot")
    [ "$slot" -ge 0 ] && [ "$slot" -lt "$losses" ]
    grep -qw in_sync "$kernel/dev-${replacement##*/}/state"
    i=$((i + 1))
done
[ "$(mdraid_checksum)" = "$checksum" ]
