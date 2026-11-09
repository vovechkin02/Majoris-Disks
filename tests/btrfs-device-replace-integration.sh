#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "${MAJORIS_DISKS_RUN_BTRFS_REPLACE_TESTS:-0}" != 1 ]; then
    echo 'SKIP: enable only on a disposable Debian 13 system'
    exit 77
fi
. /etc/os-release
if [ "$ID:$VERSION_ID" != debian:13 ] || [ "$(id -u)" != 0 ]; then
    echo 'SKIP: requires disposable Debian 13 with root'
    exit 77
fi
for command in losetup mkfs.btrfs btrfs blkid findmnt udisksctl udevadm sha256sum unshare blockdev; do
    command -v "$command" >/dev/null || { echo "SKIP: missing $command"; exit 77; }
done
if ! losetup -f >/dev/null || ! udisksctl status >/dev/null; then
    echo 'SKIP: requires loop devices and a running UDisks service'
    exit 77
fi
helper=$(realpath "$1")
status_helper=$(dirname "$helper")/majoris-disks-btrfs-status
scenario=${2:-healthy}
if [ "$scenario" = failing ]; then
    if ! command -v dmsetup >/dev/null || ! modprobe dm-flakey; then
        echo 'SKIP: failing-member fixture requires dmsetup and dm-flakey'
        exit 77
    fi
fi
if [ "${3:-}" != namespace ]; then
    if ! unshare --mount --propagation private true; then
        echo 'SKIP: cannot create a private mount namespace'
        exit 77
    fi
    exec unshare --mount --propagation private sh "$0" "$helper" "$scenario" namespace
fi

fixture=$(mktemp -d)
left= right= target= uuid= worker= target_uuid= rule= target_link= mapping= mapping_uuid=
mkdir "$fixture/mount"
owns() {
    losetup -j "$fixture/$1.img" | grep -q -F "$2:"
}
cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null; then
        echo "Replacement worker still exists. Retained $fixture and its devices." >&2
        exit 1
    fi
    if mountpoint -q "$fixture/mount"; then
        if ! findmnt -n -o UUID --mountpoint "$fixture/mount" | grep -Fxq "$uuid" ||
           ! umount "$fixture/mount"; then
            echo "Mount identity or cleanup failed. Retained $fixture." >&2
            exit 1
        fi
    fi
    if mountpoint -q "$fixture/target-mount"; then
        if ! owns target "$target" ||
           ! findmnt -n -o UUID --mountpoint "$fixture/target-mount" | grep -Fxq "$target_uuid" ||
           ! umount "$fixture/target-mount"; then
            echo "Target mount identity or cleanup failed. Retained $fixture." >&2
            exit 1
        fi
    fi
    if [ -n "$target_link" ]; then
        if [ "$(readlink "$target_link")" != "$target" ] || ! rm -- "$target_link"; then
            echo "Target symlink identity or cleanup failed. Retained $fixture." >&2
            exit 1
        fi
    fi
    if [ -n "$mapping" ]; then
        if ! owns right "$right" ||
           [ "$(dmsetup info -c --noheadings -o uuid "$mapping" | tr -d '[:space:]')" != "$mapping_uuid" ] ||
           ! dmsetup remove "$mapping"; then
            echo "Device-mapper identity or cleanup failed. Retained $fixture." >&2
            exit 1
        fi
    fi
    for slot in target right left; do
        case "$slot" in target) node=$target;; right) node=$right;; left) node=$left;; esac
        if [ -n "$node" ] && { ! owns "$slot" "$node" || ! losetup -d "$node"; }; then
            echo "Could not safely detach $slot. Retained $fixture." >&2
            exit 1
        fi
    done
    if [ -n "$rule" ]; then
        rm -f "$rule"
        udevadm control --reload
    fi
    rm -f "$fixture/left.img" "$fixture/right.img" "$fixture/target.img" "$fixture/result"
    [ ! -d "$fixture/target-mount" ] || rmdir "$fixture/target-mount"
    rmdir "$fixture/mount" "$fixture"
    exit "$rc"
}
trap cleanup EXIT
mkdir -p /run/udev/rules.d
rule=$(mktemp /run/udev/rules.d/99-majoris-btrfs-XXXXXXXX.rules)
for slot in left right target; do
    printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' \
        "$fixture/$slot.img"
done >"$rule"
udevadm control --reload
new_loop() {
    truncate -s "$2" "$fixture/$1.img"
    losetup --find --show --nooverlap "$fixture/$1.img"
}
devno() {
    set -- $(stat -Lc '%t %T' "$1")
    major=$((0x$1))
    minor=$((0x$2))
    printf '%s\n' "$(( (major & 4095) << 8 | (major & ~4095) << 32 | (minor & 255) | (minor & ~255) << 12 ))"
}
status() {
    "$helper" replace-status "$fixture/mount" "$uuid" "$anchor_number"
}
start() {
    "$helper" replace-start "$fixture/mount" "$uuid" "$anchor_number" 2 "$source_id" "$source_uuid" "$source_number" "$@"
}
review() {
    "$status_helper" replace-check "$fixture/mount" "$uuid" "$anchor_number" 2 "$source_id" "$source_uuid" "$source_number" "$@"
}
reject() {
    if "$@"; then
        echo 'An invalid replacement request unexpectedly succeeded' >&2
        exit 1
    fi
}

left=$(new_loop left 768M)
right=$(new_loop right 768M)
target_size=768M
[ "$scenario" != larger ] || target_size=1G
[ "$scenario" != small ] || target_size=512M
target=$(new_loop target "$target_size")
owns left "$left"
owns right "$right"
owns target "$target"
test "$left" != "$right"
test "$left" != "$target"
test "$right" != "$target"
uuid=$(cat /proc/sys/kernel/random/uuid)
source_device=$right
if [ "$scenario" = failing ]; then
    candidate=majoris-btrfs-replace-${fixture##*/}
    mapping_uuid=majoris-btrfs-replace-$uuid
    sectors=$(blockdev --getsz "$right")
    dmsetup create "$candidate" --uuid "$mapping_uuid" --table "0 $sectors linear $right 0"
    mapping=$candidate
    source_device=/dev/mapper/$mapping
fi
data_profile=raid1
[ "$scenario" != nonredundant ] || data_profile=raid0
mkfs.btrfs -q -U "$uuid" -d "$data_profile" -m raid1 "$left" "$source_device"
source_id=$(btrfs inspect-internal dump-super "$source_device" | awk '$1 == "dev_item.devid" {print $2}')
source_uuid=$(blkid -p -s UUID_SUB -o value "$source_device")
source_number=$(devno "$source_device")
anchor_number=$(devno "$left")
mount -o "device=$source_device,subvolid=5" "$left" "$fixture/mount"
dd if=/dev/urandom of="$fixture/mount/payload" bs=1M count=128 status=none
checksum=$(sha256sum "$fixture/mount/payload")
sync -f "$fixture/mount"
if [ "$scenario" = failing ]; then
    dmsetup reload "$mapping" --table "0 $sectors flakey $right 0 0 1 1 error_reads"
    dmsetup suspend "$mapping" --noflush
    dmsetup resume "$mapping"
    btrfs scrub start -Br "$fixture/mount" || true
    btrfs device stats "$fixture/mount" |
        awk '$1 ~ /\.read_io_errs$/ && $2 > 0 { found = 1 } END { exit !found }'
fi
if [ "$scenario" = missing ]; then
    umount "$fixture/mount"
    btrfs device scan --forget "$right"
    owns right "$right"
    losetup -d "$right"
    right=
    source_number=0
    mount -o degraded,subvolid=5 "$left" "$fixture/mount"
fi

udevadm settle
target_number=$(devno "$target")
target_bytes=$(blockdev --getsize64 "$target")
target_name=${target##*/}
sequence=$(cat "/sys/class/block/$target_name/diskseq")
object=$(udisksctl info -b "$target" | sed -n '1s/:$//p')
test -n "$object"
avoid=0
[ "$scenario" != prefer-survivor ] || avoid=1
[ "$scenario" != failing ] || avoid=1
[ "$scenario" != nonredundant ] || avoid=1
set -- "$target_number" "$target" "$target_bytes" "$sequence" "$object" "$avoid"
test "$(status | cut -d ' ' -f 1)" = 0
if [ "$scenario" = small ] || [ "$scenario" = nonredundant ]; then
    reject review "$@"
    reject start "$@"
    test "$(status | cut -d ' ' -f 1)" = 0
    test "$(sha256sum "$fixture/mount/payload")" = "$checksum"
    exit 0
fi
if [ "$scenario" = unsafe ]; then
    reject start "$target_number" "$target" "$target_bytes" "$((sequence + 1))" "$object" 0
    reject start "$target_number" "$fixture/unknown" "$target_bytes" "$sequence" "$object" 0
    link=/dev/majoris-btrfs-replace-${fixture##*/}
    ln -s -- "$target" "$link"
    target_link=$link
    reject start "$target_number" "$target_link" "$target_bytes" "$sequence" "$object" 0
    reject start "$source_number" "$right" "$target_bytes" "$sequence" "$object" 0
    reject "$helper" replace-status "$fixture/mount" invalid "$anchor_number"
    reject "$helper" replace-status "$fixture/mount" 00000000-0000-0000-0000-000000000000 "$anchor_number"
    reject "$helper" replace-unknown "$fixture/mount" "$uuid" "$anchor_number"
    reject "$helper" replace-start "$fixture/mount" "$uuid" "$anchor_number" 2 0 "$source_uuid" "$source_number" "$@"
    reject "$helper" replace-start "$fixture/mount" "$uuid" "$anchor_number" 2 "$source_id" "$uuid" "$source_number" "$@"
    reject "$helper" replace-cancel "$fixture/mount" "$uuid" "$anchor_number" 1
    reject "$status_helper" replace-start "$fixture/mount" "$uuid" "$anchor_number" 2 "$source_id" "$source_uuid" "$source_number" "$@"
    mount -o remount,ro "$fixture/mount"
    reject start "$@"
    mount -o remount,rw "$fixture/mount"
    target_uuid=$(cat /proc/sys/kernel/random/uuid)
    owns target "$target"
    test "$(cat "/sys/class/block/$target_name/diskseq")" = "$sequence"
    mkfs.btrfs -q -U "$target_uuid" "$target"
    udevadm settle
    reject review "$@"
    reject start "$@"
    mkdir "$fixture/target-mount"
    mount "$target" "$fixture/target-mount"
    reject start "$@"
    test "$(blkid -p -s UUID -o value "$target")" = "$target_uuid"
    test "$(status | cut -d ' ' -f 1)" = 0
    test "$(sha256sum "$fixture/mount/payload")" = "$checksum"
    exit 0
fi

test "$(review "$@" | cut -d ' ' -f 1)" = 0
test "$(status | cut -d ' ' -f 1)" = 0
start "$@" >"$fixture/result" &
worker=$!
attempt=0
while kill -0 "$worker" 2>/dev/null; do
    current=$(status)
    echo "$current"
    set -- $current
    if [ "$scenario" = cancel ] && [ "$1" = 1 ]; then
        if cancelled=$("$helper" replace-cancel "$fixture/mount" "$uuid" "$anchor_number" "$3"); then
            test "${cancelled%% *}" = 3
        fi
        break
    fi
    attempt=$((attempt + 1))
    test "$attempt" -lt 600
    sleep 0.1
done
result=0
wait "$worker" || result=$?
worker=
current=$(status)
if [ "$result" != 0 ] && [ "${current%% *}" = 2 ]; then
    btrfs filesystem usage "$fixture/mount"
    btrfs filesystem show "$fixture/mount"
fi
case "$scenario:${current%% *}" in
    cancel:3)
        btrfs filesystem show "$fixture/mount" | grep -F "$right"
        ;;
    cancel:2)
        test "$result" = 0
        echo 'Replacement finished before cancellation could be confirmed'
        ;;
    *:2)
        test "$result" = 0
        test "$(cut -d ' ' -f 1 "$fixture/result")" = 2
        test "$(blkid -p -s UUID -o value "$target")" = "$uuid"
        btrfs filesystem show "$fixture/mount" | grep -E "devid[[:space:]]+$source_id[[:space:]].*path $target$"
        if [ "$scenario" = larger ]; then
            member_bytes=$(btrfs inspect-internal dump-super "$target" | awk '$1 == "dev_item.total_bytes" {print $2}')
            test "$member_bytes" = "$((768 * 1024 * 1024))"
            test "$target_bytes" -gt "$member_bytes"
        fi
        if [ "$scenario" = missing ]; then
            umount "$fixture/mount"
            mount -o "device=$target,subvolid=5" "$left" "$fixture/mount"
        fi
        ;;
    *) echo "Unexpected replacement result: $current (worker $result)" >&2; exit 1;;
esac
test "$(sha256sum "$fixture/mount/payload")" = "$checksum"
