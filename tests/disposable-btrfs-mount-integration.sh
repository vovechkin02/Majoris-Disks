#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "${MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS:-0}" != 1 ]; then
    echo 'SKIP: opt in on a disposable Linux test system with MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS=1'
    exit 77
fi
for command in mkfs.btrfs btrfs blkid mount mountpoint umount unshare; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "SKIP: $command is unavailable"
        exit 77
    fi
done
if [ "$(id -u)" != 0 ] || ! unshare --mount --propagation private true; then
    echo 'SKIP: an isolated root mount namespace is unavailable'
    exit 77
fi
if [ "${2:-}" != namespace ]; then
    exec unshare --mount --propagation private sh "$0" "$1" namespace
fi

fixture=$(mktemp -d)
cleanup() {
    umount "$fixture/target-bind" 2>/dev/null || :
    umount "$fixture/other-bind" 2>/dev/null || :
    umount "$fixture/target" 2>/dev/null || :
    umount "$fixture/other" 2>/dev/null || :
    for path in target-bind other-bind target other; do
        if mountpoint -q "$fixture/$path"; then
            echo "Fixture cleanup incomplete; retained $fixture" >&2
            return 1
        fi
    done
    rm -f "$fixture/target.img" "$fixture/other.img"
    rmdir "$fixture/target-bind" "$fixture/other-bind" "$fixture/target" "$fixture/other" "$fixture"
}
trap cleanup EXIT
mkdir "$fixture/target" "$fixture/other" "$fixture/target-bind" "$fixture/other-bind"
leaf=majoris-mount-identity
for volume in target other; do
    truncate -s 256M "$fixture/$volume.img"
    mkfs.btrfs -q "$fixture/$volume.img"
    mount -o loop,subvolid=5 "$fixture/$volume.img" "$fixture/$volume"
    btrfs subvolume create "$fixture/$volume/$leaf"
done
uuid=$(blkid -s UUID -o value "$fixture/target.img")
target_id=$(btrfs subvolume show "$fixture/target/$leaf" | awk '/Subvolume ID:/ { print $NF }')
other_id=$(btrfs subvolume show "$fixture/other/$leaf" | awk '/Subvolume ID:/ { print $NF }')
test -n "$target_id"
test "$target_id" = "$other_id"
mount --bind "$fixture/other/$leaf" "$fixture/other-bind"
"$1" --mount-use "$uuid" "$target_id" "$leaf" 0
mount --bind "$fixture/target/$leaf" "$fixture/target-bind"
"$1" --mount-use "$uuid" "$target_id" "$leaf" 1
