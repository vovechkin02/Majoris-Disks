#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
skip() { echo "SKIP: $*"; exit 77; }
[ "${MAJORIS_DISKS_RUN_NBD_IOCTL_TESTS:-0}" = 1 ] ||
    skip 'Enable the foreground-client fixture only in a dedicated Debian 13 QEMU guest'
[ "$(id -u)" = 0 ] && [ "$(systemd-detect-virt --vm)" = qemu ] || skip 'Requires root in QEMU'
. /etc/os-release
[ "$ID:$VERSION_ID" = debian:13 ] || skip 'Requires Debian 13'
test -x "$1" && test -x "$2"
[ -x /usr/sbin/nbd-client ] && [ -r /sys/module/nbd/parameters/max_part ] ||
    skip 'Requires nbd-client and the existing partition-capable NBD module'
[ "$(cat /sys/module/nbd/parameters/max_part)" -gt 0 ] || skip 'NBD partition support is disabled'
command -v blockdev >/dev/null || skip 'blockdev is required to restore the fixture device flag'

name=com.majoris.disks.Nbd
owner_call() {
    busctl --system call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus "$1" s "$name"
}
[ "$(owner_call NameHasOwner)" = 'b false' ] || skip 'Start before the normal NBD helper has been activated'
for node in /sys/block/nbd[0-9]*; do
    [ -r "$node/size" ] || skip 'No NBD device is available'
    [ "$(cat "$node/size")" = 0 ] && [ ! -e "$node/pid" ] ||
        skip 'An existing NBD mapping is present'
done
fixture=$(mktemp -d)
for node in /sys/block/nbd[0-9]*; do cat "$node/ro" > "$fixture/${node##*/}"; done
"$1" &
helper=$!
trap 'kill "$helper" 2>/dev/null || :; wait "$helper" 2>/dev/null || :; rm -f -- "$fixture"/nbd[0-9]*; rmdir "$fixture"' EXIT
trap 'exit 1' INT TERM
for attempt in $(seq 1 40); do
    owner=$(owner_call GetNameOwner 2>/dev/null) || owner=
    if [ -n "$owner" ]; then break; fi
    kill -0 "$helper"
    sleep 0.25
done
owner=$(printf '%s\n' "$owner" | sed -n 's/^s "\(:[^"]*\)"$/\1/p')
[ -n "$owner" ]
pid=$(busctl --system call org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus GetConnectionUnixProcessID s "$owner")
[ "$pid" = "u $helper" ]
echo "Test-only ioctl helper $helper owns $name as $owner"
status=0
output=$(MAJORIS_DISKS_RUN_NBD_TESTS=1 "$2" --nbd --kill-client 2>&1) || status=$?
printf '%s\n' "$output"
test "$status" = 0 || exit "$status"
index=$(printf '%s\n' "$output" | sed -n 's/^Pinned NBD client .* index \([0-9][0-9]*\)$/\1/p')
sequence=$(printf '%s\n' "$output" | sed -n 's/^Pinned NBD client .* diskseq \([0-9][0-9]*\), .*$/\1/p')
case "$index" in ''|*[!0-9]*) exit 1 ;; esac
node=/sys/block/nbd$index
[ -n "$sequence" ] && [ "$(cat "$node/diskseq")" = "$sequence" ]
[ "$(cat "$node/size")" = 0 ] && [ ! -e "$node/pid" ]
if [ "$(cat "$fixture/nbd$index")" = 0 ] && [ "$(cat "$node/ro")" = 1 ]; then
    # nbd-client's ioctl setup uses BLKROSET. Netlink updates the disk flag
    # but does not clear an inherited block-device flag on the same index.
    blockdev --setrw "/dev/nbd$index"
    echo "Restored the test-owned idle nbd$index block-device flag"
fi
