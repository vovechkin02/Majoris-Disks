#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the prepare and verify phases on opposite sides of a disposable guest reboot.
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
helper=$(realpath "$1")
observer=$(dirname "$helper")/majoris-disks-btrfs-status
phase=$2
loop= uuid=
if [ "$phase" = prepare ]; then
    fixture=$(mktemp -d /var/tmp/majoris-scrub-reboot.XXXXXXXX)
    mkdir "$fixture/mount"
elif [ "$phase" = verify ]; then
    fixture=$3
    case $fixture in /var/tmp/majoris-scrub-reboot.????????) ;; *) exit 1;; esac
    test "$(realpath "$fixture")" = "$fixture"
    test "$(stat -c '%u:%a' "$fixture")" = 0:700
    test "$(cat "$fixture/boot-id")" != "$(cat /proc/sys/kernel/random/boot_id)"
else
    exit 1
fi

image=$fixture/image
mnt=$fixture/mount
owns_loop() { losetup -j "$image" | cut -d: -f1 | grep -Fxq "$loop"; }
owns_mount() {
    owns_loop &&
    [ "$(findmnt -nro SOURCE --mountpoint "$mnt")" = "$loop" ] &&
    [ "$(findmnt -nro UUID --mountpoint "$mnt")" = "$uuid" ]
}
cleanup() {
    rc=$?
    trap - EXIT
    if mountpoint -q "$mnt" && { ! owns_mount || ! umount "$mnt"; }; then
        echo "Mount cleanup failed; retained $fixture" >&2
        exit 1
    fi
    if [ -n "$loop" ] && { ! owns_loop || ! losetup -d "$loop"; }; then
        echo "Loop cleanup failed; retained $fixture" >&2
        exit 1
    fi
    if [ -n "$uuid" ]; then
        rm -f -- "/var/lib/btrfs/scrub.status.$uuid" "/var/lib/majoris-disks-scrub/$uuid"
    fi
    rm -f -- "$image" "$fixture/boot-id" "$fixture/uuid" "$fixture/hash" "$fixture/report"
    rmdir "$mnt" "$fixture"
    exit "$rc"
}
trap cleanup EXIT
if [ "$phase" = prepare ]; then
    truncate -s 2G "$image"
else
    test -f "$image" && test ! -L "$image"
    test "$(blkid -p -s UUID -o value "$image")" = "$(cat "$fixture/uuid")"
fi
loop=$(losetup --find --show --nooverlap "$image")
owns_loop
if [ "$phase" = prepare ]; then mkfs.btrfs -q "$loop"; fi
uuid=$(blkid -p -s UUID -o value "$loop")
test -n "$uuid"
if [ "$phase" = verify ]; then test "$uuid" = "$(cat "$fixture/uuid")"; fi
mount -o subvolid=5 "$loop" "$mnt"
owns_mount
dev=$(stat -c %r "$loop")
checkpoint=/var/lib/btrfs/scrub.status.$uuid
if [ "$phase" = prepare ]; then
    cat /proc/sys/kernel/random/boot_id >"$fixture/boot-id"
    printf '%s\n' "$uuid" >"$fixture/uuid"
    dd if=/dev/zero of="$mnt/payload" bs=4M count=128 conv=fsync status=none
    sha256sum "$mnt/payload" >"$fixture/hash"
    owns_mount
    echo 4194304 >"/sys/fs/btrfs/$uuid/devinfo/1/scrub_speed_max"
    systemd-run --quiet --unit="majoris-scrub-$uuid" \
        "$helper" scrub-readonly "$mnt" "$uuid" "$dev" 1
    for attempt in $(seq 1 300); do
        if [ -f "$checkpoint" ] && grep -Eq '\|last_physical:[1-9][0-9]*\|' "$checkpoint"; then break; fi
        sleep 0.1
    done
    grep -Eq '\|last_physical:[1-9][0-9]*\|' "$checkpoint"
    "$observer" scrub-status "$mnt" "$uuid" "$dev" 1 | grep -q '^running '
    sync
    trap - EXIT
    printf '%s\n' "$fixture"
else
    "$observer" scrub-status "$mnt" "$uuid" "$dev" 1 | grep -Eq '^(resumable|interrupted) readonly [0-9]+ 0 1 '
    "$helper" scrub-resume "$mnt" "$uuid" "$dev" 1 >"$fixture/report"
    cat "$fixture/report"
    grep -Eq '^(clean|unverified) readonly ' "$fixture/report"
    grep -Eq '\|t_resumed:[1-9][0-9]*\|' "$checkpoint"
    sha256sum --check "$fixture/hash"
    "$observer" scrub-history "$mnt" "$uuid" "$dev" 1 | grep -Eq '^(clean|unverified) readonly '
fi
