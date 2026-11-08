#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "${MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS:-0}" != 1 ]; then
    echo 'SKIP: opt in on a disposable Linux test system with MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS=1'
    exit 77
fi
for command in mkfs.btrfs btrfs blkid fallocate findmnt losetup mount mountpoint umount unshare; do
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
namespace_worker=
extra_loop=
cleanup() {
    if [ -n "$namespace_worker" ]; then
        touch "$fixture/namespace-stop"
        wait "$namespace_worker" || :
    fi
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
    if [ -n "$extra_loop" ]; then
        if ! losetup -j "$fixture/extra.img" | grep -q -F "$extra_loop:" || ! losetup -d "$extra_loop"; then
            echo "Loop cleanup incomplete; retained $fixture" >&2
            return 1
        fi
    fi
    rm -f "$fixture/target.img" "$fixture/other.img" "$fixture/extra.img" "$fixture/namespace-ready" "$fixture/namespace-stop"
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
umount "$fixture/target-bind"
"$1" --mount-use "$uuid" "$target_id" "$leaf" 0
unshare --mount --propagation private sh -eu -c '
    mount --bind "$1/target/$2" "$1/target-bind"
    touch "$1/namespace-ready"
    for attempt in $(seq 1 200); do
        if [ -f "$1/namespace-stop" ]; then break; fi
        sleep 0.05
    done
    umount "$1/target-bind"
' sh "$fixture" "$leaf" &
namespace_worker=$!
for attempt in $(seq 1 100); do
    if [ -f "$fixture/namespace-ready" ]; then break; fi
    kill -0 "$namespace_worker"
    sleep 0.05
done
test -f "$fixture/namespace-ready"
! mountpoint -q "$fixture/target-bind"
"$1" --mount-use "$uuid" "$target_id" "$leaf" 1
touch "$fixture/namespace-stop"
wait "$namespace_worker"
namespace_worker=
"$1" --mount-use "$uuid" "$target_id" "$leaf" 0
helper=$(dirname "$1")/src/majoris-disks-btrfs-default
source=$(findmnt -n -o SOURCE --mountpoint "$fixture/target" | sed 's/\[.*$//')
test -b "$source"
source_number=$(stat -c '%r' "$source")
truncate -s 1G "$fixture/extra.img"
extra_loop=$(losetup --find --show --nooverlap "$fixture/extra.img")
losetup -j "$fixture/extra.img" | grep -q -F "$extra_loop:"
test "$extra_loop" != "$source"
extra_number=$(stat -c '%r' "$extra_loop")
btrfs device add --nodiscard "$extra_loop" "$fixture/target"
"$1" --allocation "$fixture/target" "$uuid" 2
"$helper" check-empty-member "$fixture/target" "$uuid" "$source_number" "$extra_number" 2
"$helper" check-removable-member "$fixture/target" "$uuid" "$source_number" "$extra_number" 2
if "$helper" check-removable-member "$fixture/target" "$uuid" "$extra_number" "$source_number" 2; then
    echo "Expected the helper to reject the active mount source" >&2
    exit 1
fi
if "$helper" check-empty-member "$fixture/target" "$uuid" "$source_number" "$extra_number" 3; then
    echo 'Expected the helper to reject a stale member count' >&2
    exit 1
fi
fallocate -l 128M "$fixture/target/relocation-probe"
sync -f "$fixture/target/relocation-probe"
if "$helper" check-empty-member "$fixture/target" "$uuid" "$source_number" "$extra_number" 2; then
    echo "Expected the fixture to allocate chunks on the larger member" >&2
    exit 1
fi
if "$helper" check-removable-member "$fixture/target" "$uuid" "$source_number" "$extra_number" 2; then
    echo "Expected the helper to reject insufficient relocation headroom" >&2
    exit 1
fi
rm "$fixture/target/relocation-probe"
btrfs device remove "$extra_loop" "$fixture/target"
"$1" --allocation "$fixture/target" "$uuid" 1
if "$helper" check-empty-member "$fixture/target" "$uuid" "$source_number" "$extra_number" 2; then
    echo 'Expected the helper to reject a device that is no longer a member' >&2
    exit 1
fi
