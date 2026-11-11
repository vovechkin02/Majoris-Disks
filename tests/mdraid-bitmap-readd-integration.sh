#!/bin/sh
# Measure actual writes to the reintroduced member, not just sync percentage.
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
scenario=${2:-bitmap}
mdraid_setup 1 2 1
if [ "$scenario" != full ]; then mdraid_call bitmap-enable - 0; fi
former=$(mdraid_loop 0)
survivor=$(mdraid_loop 1)
replacement=$(mdraid_loop 2)
slot=$(cat "$kernel/dev-${former##*/}/slot")
former_uuid=$(mdadm --examine --export "$former" | sed -n 's/^MD_DEV_UUID=//p')
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
target=$former
[ "$scenario" != full ] || target=$replacement
before=$(awk '{ print $7 }' "/sys/class/block/${target##*/}/stat")
mdadm --examine --export "$former"
mdadm --examine --export "$survivor"
component=$(cat "$kernel/component_size")
printf 'Degraded write: 1 MiB at 8 MiB; component: %s KiB\n' "$component"
if [ "$scenario" != full ]; then
    mdadm --examine-bitmap "$survivor"
    old_events=$(mdadm --examine --export "$former" | sed -n 's/^MD_EVENTS=//p')
    live_events=$(mdadm --examine --export "$survivor" | sed -n 's/^MD_EVENTS=//p')
    [ "$((live_events - old_events))" -gt 1 ]
    operation=re-add-member
else
    if (mdraid_call review-readd "$former" 1) > "$fixture/review.log" 2>&1; then
        printf 'A stale member without a bitmap was accepted for review\n' >&2
        exit 1
    fi
    cat "$fixture/review.log"
    grep -Fq 'Bitmap history could not be verified' "$fixture/review.log"
    operation=replace
fi
if [ "$scenario" = faults ]; then
    faults=$(realpath "$3")
    mdraid_refresh
    for fault in truncate read-error missing offset disk-offset format uuid flags chunk events history stale unknown \
                 reports former-newer former-geometry former-array former-version former-slot; do
        if env MAJORIS_MDRAID_BITMAP_FAULT="$fault" MAJORIS_MDRAID_CHURN_DEVICE="$former" LD_PRELOAD="$faults" \
            "$service" re-add-member "$fixture" "$array_uuid" "$md" "$former" 1 > "$fixture/fault.log" 2>&1; then
            echo "Unexpected re-add acceptance with bitmap fault $fault" >&2
            exit 1
        fi
        case "$fault" in
            stale) diagnostic='predates the retained bitmap history' ;;
            reports) diagnostic='kernel bitmap configuration could not be verified' ;;
            former-newer|former-geometry) diagnostic='member metadata are incompatible' ;;
            former-array|former-version|former-slot) diagnostic='superblock and slot could not be verified' ;;
            *) diagnostic='Bitmap history could not be verified' ;;
        esac
        cat "$fixture/fault.log"
        grep -Fq "$diagnostic" "$fixture/fault.log"
        [ ! -e "$kernel/dev-${former##*/}" ]
        [ "$(cat "$kernel/degraded")" = 1 ]
        printf 'Rejected bitmap fault %s\n' "$fault"
    done
    env MAJORIS_MDRAID_HELPER_FAULT=member-uuid LD_PRELOAD="$faults" \
        "$service" expect-readd-rejection "$fixture" "$array_uuid" "$md" "$former" 1
    [ ! -e "$kernel/dev-${former##*/}" ]
    [ "$(dd if="$md" bs=1M count=16 status=none | sha256sum)" = "$payload" ]
    exit 0
fi
case "$scenario" in
    review-churn|authorization-churn|helper-churn|reuse|moved|bitmap-changed)
        faults=$(realpath "$3")
        churn_script=$(realpath "$(dirname "$0")/mdraid-target-churn.sh")
        mode=$scenario
        churn_action=reject-target-disappearance
        if [ "$scenario" = reuse ] || [ "$scenario" = moved ]; then
            mode=authorization-churn
            churn_action=reject-target-$scenario
        fi
        mdraid_refresh
        env MAJORIS_MDRAID_HELPER_FAULT="$mode" MAJORIS_MDRAID_CHURN_SCRIPT="$churn_script" \
            MAJORIS_MDRAID_CHURN_FIXTURE="$fixture" MAJORIS_MDRAID_CHURN_DEVICE="$former" \
            MAJORIS_MDRAID_CHURN_ACTION="$churn_action" LD_PRELOAD="$faults" \
            "$service" expect-readd-rejection "$fixture" "$array_uuid" "$md" "$former" 1
        [ ! -e "$kernel/dev-${former##*/}" ]
        [ "$(cat "$kernel/degraded")" = 1 ]
        [ "$(dd if="$md" bs=1M count=16 status=none | sha256sum)" = "$payload" ]
        exit 0 ;;
esac
if [ "$scenario" = post-attach-loss ] || [ "$scenario" = restart ]; then
    printf '4096\n' > "$kernel/sync_speed_min"
    printf '4096\n' > "$kernel/sync_speed_max"
    mdraid_refresh
    "$service" expect-readd-interruption "$fixture" "$array_uuid" "$md" "$former" 1 > "$fixture/interruption.log" 2>&1 &
    initiator=$!
    for attempt in $(seq 1 100); do
        [ "$(cat "$kernel/sync_action")" = recover ] && break
        kill -0 "$initiator" || { cat "$fixture/interruption.log"; exit 1; }
        sleep 0.2
    done
    [ "$(cat "$kernel/sync_action")" = recover ]
    [ "$(cat "$kernel/dev-${former##*/}/slot")" = "$slot" ]
    sleep 1
    if [ "$scenario" = post-attach-loss ]; then
        [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
        mdraid_owned_loop "$former" "$fixture/member-0.img"
        [ "$(mdadm --examine --export "$former" | sed -n 's/^MD_DEV_UUID=//p')" = "$former_uuid" ]
        mdadm --manage "$md" --fail "$former"
        for attempt in $(seq 1 100); do
            [ "$(cat "$kernel/sync_action")" = idle ] &&
                grep -qw faulty "$kernel/dev-${former##*/}/state" && break
            sleep 0.1
        done
        [ "$(cat "$kernel/sync_action")" = idle ]
        grep -qw faulty "$kernel/dev-${former##*/}/state"
        mdadm --manage "$md" --remove "$former"
        mdraid_detach_member "$former"
    else
        systemctl restart udisks2
    fi
    result=0
    wait "$initiator" || result=$?
    initiator=
    cat "$fixture/interruption.log"
    [ "$result" = 0 ]
    if [ "$scenario" = post-attach-loss ]; then
        [ ! -e "$kernel/dev-${former##*/}" ]
        [ "$(cat "$kernel/degraded")" = 1 ]
        [ "$(cat "$kernel/dev-${survivor##*/}/state")" = in_sync ]
        [ "$(dd if="$md" bs=1M count=16 status=none | sha256sum)" = "$payload" ]
        exit 0
    fi
    mdraid_call observe-terminal "$former" 0
elif [ "$scenario" = interruption ]; then
    faults=$(realpath "$3")
    mdraid_refresh
    for mode in verification-timeout kill-before kill-after; do
        env MAJORIS_MDRAID_HELPER_FAULT="$mode" LD_PRELOAD="$faults" \
            "$service" expect-readd-interruption "$fixture" "$array_uuid" "$md" "$former" 1
        if [ "$mode" != kill-after ]; then
            [ ! -e "$kernel/dev-${former##*/}" ]
            [ "$(cat "$kernel/degraded")" = 1 ]
        fi
    done
    [ -e "$kernel/dev-${former##*/}" ]
else
    (while [ -e "$kernel/sync_action" ]; do
        printf '%s %s\n' "$(cat "$kernel/sync_action")" "$(cat "$kernel/sync_completed")"
        sleep 0.1
    done) > "$fixture/sync.log" &
    observer=$!
    mdraid_call "$operation" "$target" 1
fi
mdadm --wait "$md" || [ "$(cat "$kernel/sync_action")" = idle ]
if [ -n "${observer:-}" ]; then
    kill "$observer"
    wait "$observer" || :
    observer=
    uniq "$fixture/sync.log"
fi
after=$(awk '{ print $7 }' "/sys/class/block/${target##*/}/stat")
sectors=$((after - before))
[ "$sectors" -gt 0 ]
[ "$(mdraid_uuid "$md")" = "$array_uuid" ]
[ "$(cat "$kernel/dev-${target##*/}/slot")" = "$slot" ]
[ "$(cat "$kernel/dev-${target##*/}/state")" = in_sync ]
[ "$(cat "$kernel/dev-${survivor##*/}/state")" = in_sync ]
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(cat "$kernel/sync_action")" = idle ]
[ "$(dd if="$md" bs=1M count=16 status=none | sha256sum)" = "$payload" ]
printf 'MEASURED %s: %s member sectors written; %s component sectors; synchronized slot %s; SHA-256 %s\n' \
    "$scenario" "$sectors" "$((component * 2))" "$slot" "$payload"
if [ "$scenario" != full ]; then
    [ "$(mdadm --examine --export "$target" | sed -n 's/^MD_DEV_UUID=//p')" = "$former_uuid" ]
    [ "$sectors" -lt "$((component * 2))" ]
else
    [ "$sectors" -ge "$((component * 2))" ]
fi
