#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
export LC_ALL=C

if [ "${MAJORIS_DISKS_RUN_BTRFS_PROFILE_TESTS:-}" != 1 ]; then
    echo 'SKIP: opt in inside a disposable Debian 13 guest with MAJORIS_DISKS_RUN_BTRFS_PROFILE_TESTS=1'
    exit 77
fi
. /etc/os-release
if [ "$(id -u)" != 0 ] || [ "$ID:$VERSION_ID" != debian:13 ]; then
    echo 'SKIP: requires root in a dedicated Debian 13 test environment'
    exit 77
fi
for tool in losetup mkfs.btrfs btrfs findmnt mountpoint udevadm pkexec sha256sum; do
    if ! command -v "$tool" >/dev/null; then
        echo "SKIP: missing $tool"
        exit 77
    fi
done
client=$(realpath "$1")
scenario=$2
fault_library=${3:-}
count=2 size=4G source_data=single source_meta=dup payload=128
data=raid1 metadata=- action=convert
case "$scenario" in
    data) ;;
    metadata) data=-; metadata=raid1 ;;
    raid1c3) count=3; source_data=raid1; source_meta=raid1; data=raid1c3 ;;
    raid1c4) count=4; source_data=raid1c3; source_meta=raid1c3; data=raid1c4; metadata=raid1c4 ;;
    raid10) count=4; source_data=raid1; source_meta=raid1; data=raid10 ;;
    dup) count=1; data=dup ;;
    missing) source_data=raid1; source_meta=raid1; data=single ;;
    combined) count=3; metadata=raid1c3 ;;
    reduce) source_data=raid1; source_meta=raid1; data=single; metadata=single; action=reduce ;;
    workspace) size=512M; data=dup; metadata=raid1; payload=96 ;;
    interrupt|cancel|monitor) size=6G; payload=512 ;;
    unsafe|restart) ;;
    faults) source_data=raid1; source_meta=raid1; data=-; metadata=single
        test -n "$fault_library"
        fault_library=$(realpath "$fault_library")
        test -f "$fault_library" ;;
    *) echo "Unknown scenario: $scenario" >&2; exit 1 ;;
esac

fixture=$(mktemp -d /var/tmp/majoris-profile.XXXXXXXX)
mountpoint="$fixture/mount"
mkdir "$mountpoint"
uuid=$(cat /proc/sys/kernel/random/uuid)
worker=
monitor=
devices=
rule="/run/udev/rules.d/99-${fixture##*/}.rules"
cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$monitor" ]; then
        kill "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
    if [ -n "$worker" ]; then
        echo "Conversion worker ownership remains unresolved. Retaining $fixture." >&2
        exit 1
    fi
    if mountpoint -q "$mountpoint"; then
        if [ "$(findmnt -n -o UUID --mountpoint "$mountpoint")" != "$uuid" ] || ! umount "$mountpoint"; then
            echo "Could not safely unmount $mountpoint. Retaining $fixture." >&2
            exit 1
        fi
    fi
    i=0
    for device in $devices; do
        i=$((i + 1))
        if ! losetup -j "$fixture/disk-$i.img" | grep -Fq "$device:" || ! losetup -d "$device"; then
            echo "Could not safely detach $device. Retaining $fixture." >&2
            exit 1
        fi
    done
    rm -f "$rule"
    udevadm control --reload-rules
    rm -f "$fixture"/disk-*.img "$fixture/result" "$fixture/diagnostic" "$fixture/monitor"
    rmdir "$mountpoint" "$fixture"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p /run/udev/rules.d
(set -C; printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s/disk-*.img", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$fixture" >"$rule")
udevadm control --reload-rules
i=0
while [ "$i" -lt "$count" ]; do
    i=$((i + 1))
    image="$fixture/disk-$i.img"
    truncate -s "$size" "$image"
    device=$(losetup --find --show --nooverlap "$image")
    devices="$devices $device"
    losetup -j "$image" | grep -Fq "$device:"
done
set -- $devices
mkfs.btrfs -f -U "$uuid" -d "$source_data" -m "$source_meta" "$@"
for device do udevadm trigger --action=change "$device"; done
udevadm settle
mount -o subvolid=5 "$1" "$mountpoint"
test "$(findmnt -n -o UUID --mountpoint "$mountpoint")" = "$uuid"
dd if=/dev/urandom of="$mountpoint/payload" bs=1M count="$payload" status=none
sync -f "$mountpoint"
checksum=$(sha256sum "$mountpoint/payload")
btrfs filesystem usage "$mountpoint"
service() {
    "$client" "$fixture" "$uuid" "$1" "${2:-$data}" "${3:-$metadata}" "$count"
}
reject() {
    reason=$1
    shift
    if service "$@" >"$fixture/diagnostic" 2>&1; then
        echo "Unexpectedly accepted $*" >&2
        exit 1
    fi
    cat "$fixture/diagnostic"
    grep -Fqi "$reason" "$fixture/diagnostic"
}
verify_profile() {
    btrfs filesystem df "$mountpoint" | awk -F '[:,]' -v category="$1" -v profile="$2" '
        $1 == category { found++; gsub(/[[:space:]]/, "", $2); if (toupper($2) != toupper(profile)) invalid++ }
        END { exit !(found && !invalid) }
    '
}

case "$scenario" in
    faults)
        helper=/usr/libexec/majoris-disks-btrfs-default
        number=$(stat -Lc %r "$1")
        review=$("$helper" balance-convert-check "$mountpoint" "$uuid" "$number" "$count" "$data" "$metadata")
        token=${review%% *}
        for fault in enospc force false-complete allocation-failure unknown-profile device-errors active-replacement unknown-exclusive active-scrub timeout; do
            rc=0
            set_timeout=30
            [ "$fault" != timeout ] || set_timeout=3
            timeout "$set_timeout" env LD_PRELOAD="$fault_library" MAJORIS_TEST_BTRFS_BALANCE_FAULT="$fault" \
                "$helper" balance-convert "$mountpoint" "$uuid" "$number" "$count" "$data" "$metadata" \
                "$token" reduce >"$fixture/diagnostic" 2>&1 || rc=$?
            cat "$fixture/diagnostic"
            case "$fault" in
                enospc) test "$rc" = 1; grep -Fq 'ran out of relocation space' "$fixture/diagnostic" ;;
                force) test "$rc" = 1; grep -Fq 'Invalid argument' "$fixture/diagnostic" ;;
                false-complete) test "$rc" = 0; grep -Fxq 'incomplete 0 0 0' "$fixture/diagnostic" ;;
                allocation-failure) test "$rc" = 1; grep -Fq 'Could not verify Btrfs allocation' "$fixture/diagnostic" ;;
                unknown-profile) test "$rc" = 1; grep -Fq 'unknown allocations prevent safe conversion' "$fixture/diagnostic" ;;
                device-errors) test "$rc" = 1; grep -Fq 'Review Replace Btrfs Device' "$fixture/diagnostic" ;;
                active-replacement|unknown-exclusive)
                    test "$rc" = 1; grep -Fq 'conflicting or unknown exclusive operation' "$fixture/diagnostic" ;;
                active-scrub) test "$rc" = 1; grep -Fq 'topology or scrub state' "$fixture/diagnostic" ;;
                timeout) test "$rc" = 124 ;;
            esac
            verify_profile Metadata raid1
            verify_profile System raid1
        done
        ;;
    workspace) reject 'insufficient verified contiguous workspace' review ;;
    unsafe)
        reject 'requires more members' review raid1c4 -
        reject 'plan changed' bad-token
        mount -o remount,ro "$mountpoint"
        reject 'read-only' review
        mount -o remount,rw "$mountpoint"
        verify_profile Data single
        for invalid in wrong-uuid wrong-count parity; do
            probe_uuid=$uuid probe_count=$count probe_target=raid1
            case "$invalid" in
                wrong-uuid) probe_uuid=00000000-0000-0000-0000-000000000000 ;;
                wrong-count) probe_count=3 ;;
                parity) probe_target=raid5 ;;
            esac
            if /usr/libexec/majoris-disks-btrfs-status balance-convert-check "$mountpoint" "$probe_uuid" \
                "$(stat -Lc %r "$1")" "$probe_count" "$probe_target" -; then
                echo "Native helper accepted $invalid" >&2
                exit 1
            fi
        done
        ;;
    restart)
        if service restart >"$fixture/diagnostic" 2>&1; then
            echo 'A reviewed plan was accepted after a UDisks restart' >&2
            exit 1
        fi
        cat "$fixture/diagnostic"
        grep -Eq 'review expired|UDisks|volume is no longer available|Operation was cancelled' "$fixture/diagnostic"
        busctl --system call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager \
            org.freedesktop.UDisks2.Manager EnableModule sb btrfs true
        verify_profile Data single
        ;;
    missing)
        umount "$mountpoint"
        losetup -j "$fixture/disk-2.img" | grep -Fq "$2:"
        losetup -d "$2"
        devices=$1
        udevadm settle
        mount -o degraded,subvolid=5 "$1" "$mountpoint"
        if service review >"$fixture/diagnostic" 2>&1; then
            echo 'Majoris accepted an incomplete member set' >&2
            exit 1
        fi
        cat "$fixture/diagnostic"
        grep -Eq 'did not identify the disposable filesystem|outside the disposable fixture|complete Btrfs member set' "$fixture/diagnostic"
        if /usr/libexec/majoris-disks-btrfs-status balance-convert-check "$mountpoint" "$uuid" \
            "$(stat -Lc %r "$1")" 2 single - >"$fixture/diagnostic" 2>&1; then
            echo 'Native helper accepted a degraded filesystem' >&2
            exit 1
        fi
        cat "$fixture/diagnostic"
        grep -Eq 'topology|missing|member set' "$fixture/diagnostic"
        ;;
    monitor)
        "$client" "$fixture" "$uuid" monitor "$data" "$metadata" "$count" >"$fixture/monitor" 2>&1 &
        monitor=$!
        "$client" "$fixture" "$uuid" convert "$data" "$metadata" "$count" >"$fixture/result" 2>&1 &
        worker=$!
        while kill -0 "$worker" 2>/dev/null && kill -0 "$monitor" 2>/dev/null; do
            if grep -q '^running ' "$fixture/monitor"; then break; fi
            sleep 0.1
        done
        kill -0 "$monitor"
        kill "$monitor"
        wait "$monitor" 2>/dev/null || true
        monitor=
        if grep -q '^running ' "$fixture/monitor"; then
            echo "Terminated an observer after it recorded a running kernel balance."
            service status
        else
            echo "Conversion finished before the observer saw it running."
        fi
        rc=0
        wait "$worker" || rc=$?
        worker=
        cat "$fixture/result"
        test "$rc" = 0
        grep -F 'allocation verified' "$fixture/result"
        ;;
    interrupt|cancel)
        "$client" "$fixture" "$uuid" convert "$data" "$metadata" "$count" >"$fixture/result" 2>&1 &
        worker=$!
        observed=
        while kill -0 "$worker" 2>/dev/null; do
            observed=$(service status)
            case "$observed" in
                running\ *)
                    # Each service invocation rediscovers status independently.
                    if [ "$scenario" = cancel ]; then
                        if service cancel; then
                            case "$(service status)" in idle\ *) observed=cancelled ;; esac
                        fi
                    elif service pause; then
                        case "$(service status)" in paused\ *) observed=paused ;; esac
                    fi
                    break ;;
            esac
        done
        rc=0
        wait "$worker" || rc=$?
        worker=
        cat "$fixture/result"
        test "$rc" = 0
        if [ "$observed" = paused ]; then
            reject 'exclusive operation' review
            service resume | grep -F 'allocation verified'
        elif [ "$observed" = cancelled ]; then
            grep -F 'Conversion interrupted' "$fixture/result"
            btrfs filesystem df "$mountpoint"
            service convert | grep -F 'allocation verified'
        else
            echo 'Control was not observed before completion. Interruption coverage was not exercised.'
            grep -F 'allocation verified' "$fixture/result"
        fi
        ;;
    reduce)
        service review | grep '^reduce '
        reject 'reviewed and confirmed' convert
        service reduce | grep -F 'allocation verified'
        ;;
    *) service "$action" | grep -F 'allocation verified' ;;
esac

case "$scenario" in
    workspace|unsafe|missing|faults|restart) ;;
    *)
        [ "$data" = - ] || verify_profile Data "$(printf '%s' "$data" | tr a-z A-Z)"
        if [ "$metadata" != - ]; then
            expected=$(printf '%s' "$metadata" | tr a-z A-Z)
            verify_profile Metadata "$expected"
            verify_profile System "$expected"
        fi ;;
esac
test "$(sha256sum "$mountpoint/payload")" = "$checksum"
test "$(findmnt -n -o UUID --mountpoint "$mountpoint")" = "$uuid"
btrfs filesystem show "$mountpoint" | grep -F "Total devices $count "
for device in $devices; do btrfs filesystem show "$mountpoint" | grep -F "path $device"; done
echo "PASS: $scenario"
