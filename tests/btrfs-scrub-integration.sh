#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "${MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS:-0}" != 1 ]; then
    echo 'SKIP: opt in only inside a disposable Debian 13 QEMU guest'
    exit 77
fi
. /etc/os-release
if [ "$ID:$VERSION_ID" != debian:13 ] || [ "$(id -u)" != 0 ] ||
    [ "$(systemd-detect-virt --vm)" != qemu ]; then
    echo 'SKIP: requires root inside a disposable Debian 13 QEMU guest'
    exit 77
fi
for program in btrfs mkfs.btrfs btrfs-map-logical filefrag findmnt blkid losetup unshare python3; do
    command -v "$program" >/dev/null || { echo "SKIP: missing $program"; exit 77; }
done
helper=$(realpath "$1")
observer=$(dirname "$helper")/majoris-disks-btrfs-status
scenario=$2
if [ "$scenario" = service ] || [ "$scenario" = interruption ]; then
    client=$(realpath "$3")
    udisksctl status >/dev/null || { echo 'SKIP: UDisks is unavailable'; exit 77; }
    busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager \
        org.freedesktop.UDisks2.Manager EnableModule sb btrfs true
elif [ "${4:-}" != namespace ]; then
    extra=${3:-}
    if [ "$scenario" = faults ]; then extra=$(realpath "$extra"); fi
    exec unshare --mount --propagation private sh "$0" "$helper" "$scenario" "$extra" namespace
fi

fixture=$(mktemp -d)
mnt=$fixture/mount
first= second= uuid= worker= rule=
owns_loop() { losetup -j "$1" | cut -d: -f1 | grep -Fxq "$2"; }
owns_mount() {
    owns_loop "$fixture/first" "$first" &&
    [ "$(findmnt -nro SOURCE --mountpoint "$mnt")" = "$first" ] &&
    [ "$(findmnt -nro UUID --mountpoint "$mnt")" = "$uuid" ]
}
cleanup() {
    result=$?
    trap - EXIT
    if [ -n "$worker" ]; then wait "$worker" || :; fi
    if mountpoint -q "$mnt" && { ! owns_mount || ! umount "$mnt"; }; then
        echo "Mount cleanup failed; retained $fixture" >&2; exit 1
    fi
    for entry in first second; do
        case $entry in first) node=$first;; second) node=$second;; esac
        if [ -n "$node" ] && { ! owns_loop "$fixture/$entry" "$node" || ! losetup -d "$node"; }; then
            echo "Loop cleanup failed; retained $fixture" >&2; exit 1
        fi
    done
    if [ -n "$uuid" ]; then
        rm -f -- "/var/lib/majoris-disks-scrub/$uuid" "/var/lib/majoris-disks-scrub/$uuid.cancelled" "/var/lib/btrfs/scrub.status.$uuid"
    fi
    if [ -n "$rule" ]; then
        rm -f -- "$rule"
        udevadm control --reload-rules
    fi
    rm -f -- "$fixture/first" "$fixture/second" "$fixture/output" "$fixture/payload" "$fixture/mapping"
    rmdir "$mnt" "$fixture"
    exit "$result"
}
trap cleanup EXIT
mkdir "$mnt"
truncate -s 1G "$fixture/first"
if [ "$scenario" = cancel ] || [ "$scenario" = interruption ] || [ "$scenario" = external ]; then truncate -s 4G "$fixture/first"; fi
if [ "$scenario" = service ] || [ "$scenario" = interruption ]; then
    rule="/run/udev/rules.d/99-majoris-scrub-${fixture##*/}.rules"
    (set -C; printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$fixture/first" >"$rule")
    udevadm control --reload-rules
fi
first=$(losetup --find --show --nooverlap "$fixture/first")
owns_loop "$fixture/first" "$first"
count=1
case $scenario in
    multi|member|corrected|metadata|degraded)
        truncate -s 1G "$fixture/second"
        second=$(losetup --find --show --nooverlap "$fixture/second")
        owns_loop "$fixture/second" "$second"
        test "$first" != "$second"
        mkfs.btrfs -q -d raid1 -m raid1 "$first" "$second"
        count=2;;
    *) mkfs.btrfs -q "$first";;
esac
if [ -n "$rule" ]; then
    owns_loop "$fixture/first" "$first"
    udevadm trigger --action=change "$first"
    udevadm settle
fi
uuid=$(blkid -s UUID -o value "$first")
mount -o subvolid=5 "$first" "$mnt"
owns_mount
source=$(stat -c %r "$first")
mutate() {
    action=$1
    shift
    owns_mount && "$helper" "$action" "$mnt" "$uuid" "$source" "$count" "$@"
}
observe() { owns_mount && "$observer" "$1" "$mnt" "$uuid" "$source" "$count"; }
observe scrub-status | grep -q '^never-run '
dd if=/dev/urandom of="$fixture/payload" bs=1M count=4 status=none
cp "$fixture/payload" "$mnt/payload"
sync
case $scenario in
    clean|multi|member)
        selector=0
        [ "$scenario" != member ] || selector=2
        mutate scrub-readonly "$selector" >"$fixture/output"
        cat "$fixture/output"
        grep -q '^clean readonly ' "$fixture/output"
        if [ "$scenario" = member ]; then
            grep -q '^device 1 .* unavailable ' "$fixture/output"
            grep -q '^device 2 .* finished ' "$fixture/output"
        else
            test "$(grep -c '^device .* finished ' "$fixture/output")" = "$count"
        fi
        cmp "$fixture/payload" "$mnt/payload"
        observe scrub-history | grep -q '^clean readonly '
        ;;
    corrected|uncorrectable|metadata)
        if [ "$scenario" = metadata ]; then
            btrfs subvolume create "$mnt/metadata-fixture"
            tree=$(btrfs inspect-internal rootid "$mnt/metadata-fixture")
            sync
        else
            logical=$(filefrag -b1 -v "$mnt/payload" | awk '$1 == "0:" { sub(/\.\..*/, "", $4); print $4; exit }')
            test -n "$logical"
        fi
        owns_mount
        umount "$mnt"
        owns_loop "$fixture/first" "$first"
        length=4096
        if [ "$scenario" = metadata ]; then
            btrfs inspect-internal dump-tree -t "$tree" "$first" >"$fixture/mapping"
            logical=$(awk '$1 == "leaf" && $0 ~ /items/ { print $2; exit }' "$fixture/mapping")
            test -n "$logical"
            length=$(btrfs inspect-internal dump-super "$first" | awk '$1 == "nodesize" { print $2 }')
        fi
        btrfs-map-logical -l "$logical" -b "$length" "$first" >"$fixture/mapping" 2>&1
        cat "$fixture/mapping"
        physical=$(awk -v dev="$first" '$1 == "mirror" && $5 == "physical" && $NF == dev { print $6; exit }' "$fixture/mapping")
        test -n "$physical"
        mirror=
        if [ -n "$second" ]; then
            owns_loop "$fixture/second" "$second"
            mirror=$(awk -v dev="$second" '$1 == "mirror" && $5 == "physical" && $NF == dev { print $6; exit }' "$fixture/mapping")
            test -n "$mirror"
        fi
        python3 - "$first" "$physical" "$fixture/payload" "$second" "$mirror" "$logical" "$length" "$scenario" <<'PY'
import os
import sys

device, offset, payload, mirror, mirror_offset, logical, length, scenario = sys.argv[1:]
offset, logical, length = map(int, (offset, logical, length))
assert offset > 1024 * 1024 and offset % 4096 == 0
if mirror:
    with open(mirror, "rb", buffering=0) as disk:
        disk.seek(int(mirror_offset))
        expected = disk.read(length)
if scenario != "metadata":
    with open(payload, "rb") as known:
        payload_sector = known.read(length)
    assert not mirror or expected == payload_sector
    expected = payload_sector
else:
    assert int.from_bytes(expected[48:56], "little") == logical
with open(device, "r+b", buffering=0) as disk:
    disk.seek(offset)
    assert disk.read(length) == expected, "target replica must match the independently verified fixture block"
    disk.seek(offset)
    if scenario == "metadata":
        damaged = bytearray(expected)
        damaged[49] ^= 1  # Change the Btrfs tree header's logical bytenr.
    else:
        damaged = bytes(byte ^ 0xff for byte in expected)
    disk.write(damaged)
    os.fsync(disk.fileno())
PY
        mount -o subvolid=5 "$first" "$mnt"
        owns_mount
        if [ "$scenario" = corrected ]; then
            mutate scrub-readonly >"$fixture/output"
            cat "$fixture/output"
            grep -q '^recoverable readonly ' "$fixture/output"
        fi
        mutate scrub-repair >"$fixture/output"
        cat "$fixture/output"
        expected=$scenario
        if [ "$scenario" = metadata ]; then
            expected=corrected
            awk '$1 == "device" && $2 == 1 && $12 > 0 && $18 > 0 { found=1 } END { exit !found }' "$fixture/output"
        fi
        grep -q "^$expected repair " "$fixture/output"
        observe scrub-history | grep -q "^$expected repair "
        if [ "$expected" = corrected ]; then
            cmp "$fixture/payload" "$mnt/payload"
            mutate scrub-readonly | grep -q '^clean readonly '
        fi
        ;;
    cancel|interruption)
        dd if=/dev/zero of="$mnt/large" bs=4M count=128 conv=fsync status=none
        owns_mount
        echo 16777216 >"/sys/fs/btrfs/$uuid/devinfo/1/scrub_speed_max"
        if [ "$scenario" = interruption ]; then
            "$client" "$fixture" "$uuid" start >"$fixture/output" &
        else
            mutate scrub-readonly >"$fixture/output" &
        fi
        worker=$!
        for attempt in $(seq 1 200); do
            if observe scrub-status | awk '$1 == "device" && $4 == "running" && $8 > 16777216 { found=1 } END { exit !found }'; then break; fi
            kill -0 "$worker"
            sleep 0.05
        done
        # A new observer can rediscover an active scrub and see live counters.
        observe scrub-status | grep -q '^device 1 .* running '
        if [ "$scenario" = interruption ]; then
            kill -TERM "$worker"
            wait "$worker" || :
            worker=
            btrfs scrub status "$mnt" | grep -Eiq 'status: +running'
            "$client" "$fixture" "$uuid" watch | grep -q '^service-running$'
            systemctl restart udisks2
            busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager \
                org.freedesktop.UDisks2.Manager EnableModule sb btrfs true
            "$client" "$fixture" "$uuid" watch | grep -q '^service-running$'
            owns_mount
            echo 0 >"/sys/fs/btrfs/$uuid/devinfo/1/scrub_speed_max"
            for attempt in $(seq 1 400); do
                observe scrub-status >"$fixture/output"
                if grep -q '^clean readonly ' "$fixture/output"; then break; fi
                if grep -Eq '^(failed|unknown|interrupted|resumable) ' "$fixture/output"; then break; fi
                sleep 0.1
            done
            cat "$fixture/output"
            grep -q '^clean readonly ' "$fixture/output"
            "$client" "$fixture" "$uuid" history | grep -q '^service-history-clean$'
        else
            mutate scrub-cancel | grep -q '^cancelled '
            wait "$worker"
            worker=
            cat "$fixture/output"
            grep -Eq '^(cancelled|interrupted) readonly [0-9]+ 0 1 ' "$fixture/output"
            observe scrub-status | grep -Eq '^(cancelled|interrupted|resumable) readonly [0-9]+ 0 1 '
            owns_mount
            checkpoint="/var/lib/btrfs/scrub.status.$uuid"
            cp "$checkpoint" "$fixture/mapping"
            sed 's/|read_errors:[0-9]*/|read_errors:18446744073709551616/' "$fixture/mapping" >"$checkpoint"
            if mutate scrub-resume; then exit 1; fi
            cp "$fixture/mapping" "$checkpoint"
            echo 0 >"/sys/fs/btrfs/$uuid/devinfo/1/scrub_speed_max"
            mutate scrub-resume >"$fixture/output"
            cat "$fixture/output"
            grep -q '^clean readonly ' "$fixture/output"
            grep -Eq '\|t_resumed:[1-9][0-9]*\|' "/var/lib/btrfs/scrub.status.$uuid"
            cmp "$fixture/payload" "$mnt/payload"
        fi
        ;;
    external)
        dd if=/dev/zero of="$mnt/large" bs=4M count=64 conv=fsync status=none
        owns_mount
        echo 16777216 >"/sys/fs/btrfs/$uuid/devinfo/1/scrub_speed_max"
        btrfs scrub start -Br "$mnt" >"$fixture/output" &
        worker=$!
        for attempt in $(seq 1 200); do
            if observe scrub-status | grep -q '^running unknown '; then break; fi
            kill -0 "$worker"
            sleep 0.05
        done
        observe scrub-status | grep -q '^running unknown '
        if mutate scrub-readonly; then exit 1; fi
        owns_mount
        echo 0 >"/sys/fs/btrfs/$uuid/devinfo/1/scrub_speed_max"
        wait "$worker"
        worker=
        test -z "$(observe scrub-history)"
        if mutate scrub-resume; then exit 1; fi
        ;;
    service)
        review=$(observe scrub-status | awk '$1 == "review" {print $2}')
        if runuser -u nobody -- /usr/bin/pkexec --disable-internal-agent \
            /usr/libexec/majoris-disks-btrfs-default scrub-readonly "$mnt" "$uuid" "$source" "$count" 0 "$review"; then
            exit 1
        fi
        observe scrub-status | grep -q '^never-run '
        "$client" "$fixture" "$uuid" start | grep -q '^service-clean$'
        "$client" "$fixture" "$uuid" history | grep -q '^service-history-clean$'
        cmp "$fixture/payload" "$mnt/payload"
        ;;
    degraded)
        owns_mount
        umount "$mnt"
        owns_loop "$fixture/second" "$second"
        losetup -d "$second"
        second=
        owns_loop "$fixture/first" "$first"
        mount -o degraded,ro,subvolid=5 "$first" "$mnt"
        if mutate scrub-repair; then exit 1; fi
        if mutate scrub-readonly; then exit 1; fi
        ;;
    faults)
        library=$3
        test -f "$library"
        for fault in active-replacement active-balance unknown-exclusive active-scrub unknown-profile device-errors; do
            owns_mount
            if env LD_PRELOAD="$library" MAJORIS_TEST_BTRFS_BALANCE_FAULT="$fault" \
                "$helper" scrub-repair "$mnt" "$uuid" "$source" "$count"; then exit 1; fi
        done
        if env LD_PRELOAD="$library" MAJORIS_TEST_BTRFS_BALANCE_FAULT=scrub-status-unavailable \
            "$observer" scrub-status "$mnt" "$uuid" "$source" "$count"; then exit 1; fi
        test -z "$(observe scrub-history)"
        ;;
    invalid)
        if observe scrub-readonly; then exit 1; fi
        if "$helper" scrub-readonly "$mnt" 00000000-0000-0000-0000-000000000000 "$source" "$count"; then exit 1; fi
        if mutate scrub-readonly 999; then exit 1; fi
        if mutate scrub-resume; then exit 1; fi
        mount -o remount,ro "$mnt"
        if mutate scrub-repair; then exit 1; fi
        mutate scrub-readonly | grep -q '^clean readonly '
        mount -o remount,rw "$mnt"
        review=$(observe scrub-status | awk '$1 == "review" {print $2}')
        owns_mount
        umount "$mnt"
        mount -o subvolid=5 "$first" "$mnt"
        if mutate scrub-readonly 0 "$review"; then exit 1; fi
        checkpoint="/var/lib/btrfs/scrub.status.$uuid"
        state="/var/lib/majoris-disks-scrub/$uuid"
        owns_mount
        sed 's/|read_errors:[0-9]*/|read_errors:18446744073709551616/' "$checkpoint" >"$fixture/output"
        cp "$fixture/output" "$checkpoint"
        if mutate scrub-resume; then exit 1; fi
        sed '$d' "$state" >"$fixture/output"
        cp "$fixture/output" "$state"
        if observe scrub-history; then exit 1; fi
        ;;
    *) echo "Unknown scenario $scenario" >&2; exit 1;;
esac
