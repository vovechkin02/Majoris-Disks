#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "${MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS:-0}" != 1 ]; then
    echo 'SKIP: opt in on a disposable Linux test system with MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS=1'
    exit 77
fi
if [ "${2:-}" != namespace ]; then
    exec unshare --mount --propagation private sh "$0" "$1" namespace
fi

fixture=$(mktemp -d)
left=
right=
owns_loop() {
    losetup -j "$fixture/$1.img" | grep -q -F "$2:"
}
cleanup() {
    status=$?
    trap - EXIT
    if mountpoint -q "$fixture/mount"; then
        if ! findmnt -n -o UUID --mountpoint "$fixture/mount" | grep -Fxq "${uuid:-unassigned}" ||
           ! umount "$fixture/mount"; then
            echo "Mount identity or cleanup failed. Retained $fixture." >&2
            exit 1
        fi
    fi
    if [ -n "$right" ] && { ! owns_loop right "$right" || ! losetup -d "$right"; }; then
        echo "Right loop identity or cleanup failed. Retained $fixture." >&2
        exit 1
    fi
    if [ -n "$left" ] && { ! owns_loop left "$left" || ! losetup -d "$left"; }; then
        echo "Left loop identity or cleanup failed. Retained $fixture." >&2
        exit 1
    fi
    rm -f "$fixture/left.img" "$fixture/right.img"
    rmdir "$fixture/mount" "$fixture"
    exit "$status"
}
trap cleanup EXIT
mkdir "$fixture/mount"
truncate -s 512M "$fixture/left.img" "$fixture/right.img"
left=$(losetup --find --show --nooverlap "$fixture/left.img")
right=$(losetup --find --show --nooverlap "$fixture/right.img")
owns_loop left "$left"
owns_loop right "$right"
test "$left" != "$right"
uuid=$(cat /proc/sys/kernel/random/uuid)
mkfs.btrfs -q -U "$uuid" -d raid1 -m raid1 "$left" "$right"
test "$(blkid -s UUID -o value "$left")" = "$uuid"
test "$(blkid -s UUID -o value "$right")" = "$uuid"
missing_id=$(btrfs inspect-internal dump-super "$right" | awk '$1 == "dev_item.devid" { print $2 }')
test -n "$missing_id"
verify_profiles() {
    report=$("$1" --allocation "$fixture/mount" "$uuid" 2 ${2:+"$2"})
    printf '%s\n' "$report"
    for kind in Data Metadata System; do
        printf '%s\n' "$report" | grep -Fxq "$kind (RAID 1)"
    done
}
mount -o "device=$right,subvolid=5" "$left" "$fixture/mount"
verify_profiles "$1"
umount "$fixture/mount"

# Stop the kernel from finding the detached member through an earlier scan.
btrfs device scan --forget "$right"
owns_loop right "$right"
losetup -d "$right"
right=
mount -o ro,degraded,subvolid=5 "$left" "$fixture/mount"
verify_profiles "$1" "$missing_id"
