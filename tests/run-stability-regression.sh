#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run from the source root inside the dedicated guest after building and installing.
set -eu
[ "${MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS:-0}" = 1 ] ||
    { echo 'Set MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS=1 only in the disposable test guest' >&2; exit 77; }
[ "$(id -u)" = 0 ] && [ "$(systemd-detect-virt --vm)" = qemu ] ||
    { echo 'A dedicated QEMU guest with root authorization is required' >&2; exit 77; }
. /etc/os-release
[ "$ID:$VERSION_ID" = debian:13 ] || { echo 'Debian 13 is required' >&2; exit 77; }
[ "$(hostname)" = majoris-mdraid-test ] ||
    { echo 'The mdraid fixtures require the disposable guest hostname majoris-mdraid-test' >&2; exit 77; }
build=${1:-build}
test -x "$build/src/majoris-disks" && test -x "$build/image-device-test" && test -x "$build/lvm-device-test"
printf 'Guest %s; user %s; kernel %s\n' "$(hostname)" "$(id -un)" "$(uname -r)"
dpkg-query -W udisks2 udisks2-lvm2 udisks2-btrfs libbtrfsutil1t64 nbd-client qemu-utils polkitd
busctl --system status org.freedesktop.UDisks2
dmsetup version
losetup --find
cat /sys/module/nbd/parameters/max_part

export MAJORIS_DISKS_RUN_LVM_TESTS=1 MAJORIS_DISKS_RUN_LOOP_TESTS=1
export MAJORIS_DISKS_RUN_IMAGING_TESTS=1 MAJORIS_DISKS_RUN_NBD_TESTS=1 MAJORIS_DISKS_RUN_MDRAID_TESTS=1
export MAJORIS_DISKS_RUN_NBD_IOCTL_TESTS=1
export MAJORIS_DISKS_RUN_BTRFS_MOUNT_TESTS=1 MAJORIS_DISKS_RUN_BTRFS_REPLACE_TESTS=1
export MAJORIS_DISKS_RUN_BTRFS_PROFILE_TESTS=1 MAJORIS_DISKS_RUN_BTRFS_QUOTA_TESTS=1 MAJORIS_DISKS_RUN_BTRFS_SCRUB_TESTS=1
export MAJORIS_TEST_LUKS=1 MAJORIS_TEST_LUKS_RESIZE=1 MAJORIS_TEST_LUKS_RESTORATION=1
export MAJORIS_TEST_MOUNT_RESTORATION=1 MAJORIS_TEST_CRYPTTAB=1
status=0
run() {
    log=$1
    shift
    meson test -C "$build" --no-rebuild --print-errorlogs --num-processes 1 --timeout-multiplier 3 \
        --logbase "$log" "$@" || status=1
}
lvm() {
    run "$1" lvm-recovery-integration lvm-cache-integration lvm-layout-integration
}

lvm stability-lvm-alone
run stability-restart lvm-recovery-restart-before-vg lvm-recovery-restart-after-vg \
    lvm-recovery-restart-after-lv lvm-recovery-restart-before-review lvm-disabled-module
lvm stability-lvm-after-restart
run stability-btrfs-order btrfs-profile-conversion-restart btrfs-quota-observer-restart-integration
lvm stability-lvm-after-btrfs
run stability-nbd-ioctl disposable-nbd-ioctl-client-termination
run stability-imaging-order disposable-loop-setup-reconciliation disposable-loop-delete-reconciliation \
    disposable-loop-restart-reconciliation disposable-loop-reuse-reconciliation \
    disposable-loop-substitute-reconciliation disposable-nbd-udisks-restart
lvm stability-lvm-after-imaging
run stability-full
exit "$status"
