#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "${MAJORIS_DISKS_RUN_BTRFS_QUOTA_TESTS:-0}" != 1 ]; then
    echo 'SKIP: requires explicit opt-in inside a disposable Debian 13 QEMU guest'
    exit 77
fi
. /etc/os-release
if [ "$ID:$VERSION_ID" != debian:13 ] || [ "$(id -u)" != 0 ] ||
   [ "$(systemd-detect-virt --vm)" != qemu ]; then
    echo 'SKIP: requires root inside a disposable Debian 13 QEMU guest'
    exit 77
fi
for command in losetup mkfs.btrfs btrfs findmnt blkid python3 timeout unshare; do
    command -v "$command" >/dev/null || { echo "SKIP: missing $command"; exit 77; }
done
helper=$(realpath "$1")
status_helper=$(dirname "$helper")/majoris-disks-btrfs-status
scenario=${2:-traditional}
if [ "$scenario" = faults ]; then
    library=$(realpath "$3")
    test -f "$library"
fi
if [ "$scenario" = service ] || [ "$scenario" = restart ]; then
    client=$(realpath "$3")
    # UDisks must see the mount in the guest's mount namespace.
    command -v udisksctl >/dev/null || { echo 'SKIP: missing UDisks'; exit 77; }
    udisksctl status >/dev/null || { echo 'SKIP: UDisks is not running'; exit 77; }
elif [ "${4:-}" != namespace ]; then
    losetup -f >/dev/null || { echo 'SKIP: no loop device available'; exit 77; }
    exec unshare --mount --propagation private sh "$0" "$helper" "$scenario" "${3:-}" namespace
fi

fixture=$(mktemp -d)
image=$fixture/quota.img
mnt=$fixture/mount
loop= uuid= rule= watcher=
owns_device() { losetup -j "$image" | cut -d: -f1 | grep -Fxq "$loop"; }
owns_mount() {
    owns_device &&
        [ "$(findmnt -nro SOURCE --mountpoint "$mnt")" = "$loop" ] &&
        [ "$(findmnt -nro UUID --mountpoint "$mnt")" = "$uuid" ]
}
cleanup() {
    result=$?
    trap - EXIT
    if [ -n "$watcher" ]; then
        kill "$watcher" 2>/dev/null || :
        wait "$watcher" 2>/dev/null || :
    fi
    if mountpoint -q "$mnt" && { ! owns_mount || ! umount "$mnt"; }; then
        echo "Fixture mount identity or cleanup failed. Retained $fixture." >&2
        exit 1
    fi
    if [ -n "$loop" ] && { ! owns_device || ! losetup -d "$loop"; }; then
        echo "Fixture loop identity or cleanup failed. Retained $fixture." >&2
        exit 1
    fi
    if [ -n "$rule" ]; then
        rm -f -- "$rule"
        udevadm control --reload-rules
    fi
    rm -f -- "$image" "$fixture/link" "$fixture/observer.log"
    rmdir -- "$mnt" "$fixture"
    exit "$result"
}
trap cleanup EXIT
mkdir "$mnt"
truncate -s 1G "$image"
if [ "$scenario" = service ] || [ "$scenario" = restart ]; then
    rule="/run/udev/rules.d/99-majoris-quota-${fixture##*/}.rules"
    (set -C; printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$image" >"$rule")
    udevadm control --reload-rules
fi
loop=$(losetup --find --show "$image")
owns_device
mkfs.btrfs -q "$loop"
if [ "$scenario" = service ] || [ "$scenario" = restart ]; then
    owns_device; udevadm trigger --action=change "$loop"
    udevadm settle
fi
uuid=$(blkid -s UUID -o value "$loop")
mount -o subvolid=5 "$loop" "$mnt"
owns_mount
dev=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_rdev)' "$loop")
sys=/sys/fs/btrfs/$uuid/qgroups

report() {
    owns_mount || return 99
    timeout 15 "$status_helper" quota-status "$mnt" "$uuid" "$dev" 1
}
token() { report | sed -n "s/.*'\([0-9a-f]\{64\}\)'.*/\1/p"; }
change() {
    action=$1
    shift
    review=$(token)
    test "${#review}" -eq 64 || return 99
    owns_mount || return 99
    timeout 30 "$helper" "$action" "$mnt" "$uuid" "$dev" 1 "$review" "$@"
}
reject() {
    code=0
    "$@" || code=$?
    if [ "$code" != 1 ]; then
        echo "Expected a validation rejection, got exit $code for $*" >&2
        exit 1
    fi
}
rootid() { btrfs inspect-internal rootid "$mnt/$1"; }
settle() {
    owns_mount
    timeout 60 btrfs quota rescan -W "$mnt"
    test "$(cat "$sys/inconsistent")" = 0
    report | grep -q "^('qgroup', uint64 1,"
}
write_result() {
    owns_mount
    python3 - "$mnt/$1" "$2" "$3" <<'PY'
import errno
import os
import sys

path, mib, expected = sys.argv[1:]
try:
    with open(path, "wb") as stream:
        os.posix_fallocate(stream.fileno(), 0, int(mib) * 1024 * 1024)
        os.fsync(stream.fileno())
except OSError as error:
    if expected != "EDQUOT" or error.errno != errno.EDQUOT:
        raise
else:
    if expected != "OK":
        raise AssertionError("write succeeded above the quota limit")
PY
}

report | grep -q "^('disabled',"
reject timeout 15 "$status_helper" quota-status "$mnt" invalid "$dev" 1
reject timeout 15 "$status_helper" quota-status "$mnt" "$uuid" "$((dev + 1))" 1
reject timeout 15 "$status_helper" quota-status "$mnt" 11111111-1111-1111-1111-111111111111 "$dev" 1
ln -s "$mnt" "$fixture/link"
reject timeout 15 "$status_helper" quota-status "$fixture/link" "$uuid" "$dev" 1
reject timeout 15 "$status_helper" quota-enable "$mnt" "$uuid" "$dev" 1 "$(token)"
reject timeout 15 runuser -u nobody -- "$helper" quota-enable "$mnt" "$uuid" "$dev" 1 "$(token)"
code=0
owns_mount
timeout 15 runuser -u nobody -- /usr/bin/pkexec --disable-internal-agent "$helper" \
    quota-enable "$mnt" "$uuid" "$dev" 1 "$(token)" || code=$?
test "$code" = 126 || test "$code" = 127
old_review=$(token)
owns_mount; umount "$mnt"
owns_device; mount -o ro,subvolid=5 "$loop" "$mnt"
reject change quota-enable
owns_mount; umount "$mnt"
owns_device; mount -o subvolid=5 "$loop" "$mnt"
owns_mount
reject timeout 30 "$helper" quota-enable "$mnt" "$uuid" "$dev" 1 "$old_review"

case "$scenario" in
restart)
    owns_mount
    btrfs subvolume create "$mnt/rescan-data"
    owns_mount
    python3 - "$mnt/rescan-data" <<'PY'
import os
import sys

data = os.urandom(8192)
for index in range(8192):
    with open(os.path.join(sys.argv[1], str(index)), "wb") as stream:
        stream.write(data)
PY
    owns_mount; btrfs filesystem sync "$mnt"
    "$client" "$fixture" "$uuid" watch >"$fixture/observer.log" 2>&1 &
    watcher=$!
    wait_for_status() {
        for iteration in $(seq 1 100); do
            grep -Fxq "$1" "$fixture/observer.log" && return 0
            kill -0 "$watcher" || break
            sleep 0.1
        done
        cat "$fixture/observer.log" >&2
        return 1
    }
    wait_for_status quotas-disabled
    change quota-enable
    wait_for_status rescan-running
    kill "$watcher"
    wait "$watcher" 2>/dev/null || :
    watcher=
    timeout 60 "$client" "$fixture" "$uuid" observe | grep -Fx 'accounting-consistent'
    settle
    change quota-disable
    ;;
faults)
    fault_status() {
        owns_mount || return 99
        timeout 15 env LD_PRELOAD="$library" MAJORIS_TEST_BTRFS_QUOTA_FAULT="$1" \
            "$status_helper" quota-status "$mnt" "$uuid" "$dev" 1
    }
    fault_mutate() {
        injection=$1
        shift
        operation=$1
        shift
        review=$(token)
        test "${#review}" -eq 64 || return 99
        owns_mount || return 99
        timeout 30 env LD_PRELOAD="$library" MAJORIS_TEST_BTRFS_QUOTA_FAULT="$injection" \
            "$helper" "$operation" "$mnt" "$uuid" "$dev" 1 "$review" "$@"
    }
    reject fault_status status-unavailable
    code=0; fault_status helper-exit || code=$?; test "$code" = 42
    code=0; fault_status status-timeout || code=$?; test "$code" = 142
    change quota-enable
    settle
    reject fault_mutate rescan-failure quota-rescan-start
    report | grep -q "^('qgroup', uint64 1,"
    code=0
    fault_mutate false-limit-success qgroup-referenced-limit 0/5 1048576 || code=$?
    test "$code" = 3
    test "$(cat "$sys/0_5/max_referenced")" = 0
    code=0
    fault_mutate limit-readback-failure qgroup-referenced-limit 0/5 1048576 || code=$?
    test "$code" = 3
    test "$(cat "$sys/0_5/max_referenced")" = 1048576
    change qgroup-referenced-limit 0/5 unlimited
    change quota-disable
    ;;
service)
    owns_mount
    timeout 120 "$client" "$fixture" "$uuid"
    ;;
traditional)
    owns_mount; btrfs subvolume create "$mnt/source"
    owns_mount; btrfs subvolume create "$mnt/other"
    src=$(rootid source)
    other=$(rootid other)
    change quota-enable | grep -q "^('qgroup',"
    test "$(cat "$sys/mode")" = qgroup
    settle
    reject change quota-enable-simple
    reject change qgroup-create 0/777
    reject change qgroup-create 65536/1
    reject change qgroup-delete "0/$src"
    reject change qgroup-referenced-limit "0/$src" 18446744073709551616
    change qgroup-referenced-limit "0/$src" 16777216
    test "$(cat "$sys/0_${src}/max_referenced")" = 16777216
    write_result source/small 4 OK
    write_result source/large 32 EDQUOT
    change qgroup-referenced-limit "0/$src" unlimited
    write_result source/large 32 OK
    owns_mount; btrfs filesystem sync "$mnt"
    test "$(cat "$sys/0_${src}/referenced")" -ge 37748736
    owns_mount; btrfs subvolume snapshot "$mnt/source" "$mnt/snapshot"
    snap=$(rootid snapshot)
    test "$(cat "$sys/0_${snap}/referenced")" -gt "$(cat "$sys/0_${snap}/exclusive")"
    change qgroup-exclusive-limit "0/$snap" 16777216
    test "$(cat "$sys/0_${snap}/max_exclusive")" = 16777216
    write_result snapshot/extra 4 OK
    write_result snapshot/oversize 32 EDQUOT
    write_result source/after-snapshot 4 OK
    owns_mount; btrfs filesystem sync "$mnt"
    test "$(cat "$sys/0_${src}/exclusive")" -ge 4194304
    test "$(cat "$sys/0_${snap}/exclusive")" -ge 4194304
    change qgroup-exclusive-limit "0/$snap" unlimited
    change qgroup-create 1/43
    change qgroup-assign "0/$snap" 1/43
    test "$(cat "$sys/inconsistent")" = 1
    reject change qgroup-referenced-limit "0/$snap" 67108864
    change quota-rescan-start
    settle
    change qgroup-unassign "0/$snap" 1/43
    change quota-rescan-start
    settle
    change qgroup-delete 1/43
    owns_mount; btrfs subvolume delete "$mnt/snapshot"
    owns_mount; btrfs filesystem sync "$mnt"
    owns_mount; btrfs subvolume sync "$mnt" "$snap"
    report
    change qgroup-create 1/42
    reject change qgroup-create 1/42
    reject change qgroup-assign "0/$src" 1/43
    reject change qgroup-assign 0/999 1/42
    reject change qgroup-assign 1/42 "0/$src"
    change qgroup-assign "0/$src" 1/42
    change qgroup-assign "0/$other" 1/42
    reject change qgroup-assign "0/$src" 1/42
    reject change qgroup-delete 1/42
    change quota-rescan-start
    # Each status invocation is a fresh helper process, including after dispatch exits.
    report
    settle
    btrfs qgroup show --raw -p "$mnt" | grep -E "0/$other[[:space:]].*1/42"
    change qgroup-referenced-limit 1/42 67108864
    write_result other/large 48 EDQUOT
    change qgroup-referenced-limit 1/42 unlimited
    change qgroup-unassign "0/$src" 1/42
    change qgroup-unassign "0/$other" 1/42
    change quota-rescan-start
    settle
    change qgroup-delete 1/42
    change qgroup-referenced-limit "0/$src" 134217728
    change quota-disable | grep -q "^('disabled',"
    report | grep -q "^('disabled',"
    if [ -e /sys/fs/btrfs/features/simple_quota ]; then
        change quota-enable-simple | grep -q "^('simple',"
        change quota-disable | grep -q "^('disabled',"
    fi
    ;;
simple)
    if [ ! -e /sys/fs/btrfs/features/simple_quota ]; then
        echo 'SKIP: kernel does not advertise simple quotas'
        exit 77
    fi
    change quota-enable-simple | grep -q "^('simple',"
    test "$(cat "$sys/mode")" = squota
    owns_mount; btrfs subvolume create "$mnt/source"
    src=$(rootid source)
    write_result source/data 8 OK
    owns_mount; btrfs subvolume snapshot "$mnt/source" "$mnt/snapshot"
    snap=$(rootid snapshot)
    owns_mount; btrfs filesystem sync "$mnt"
    test "$(cat "$sys/0_${src}/referenced")" -ge 8388608
    test "$(cat "$sys/0_${snap}/referenced")" -lt 8388608
    reject change quota-rescan-start
    reject change qgroup-exclusive-limit "0/$src" 1048576
    reject change qgroup-create 1/42
    change qgroup-referenced-limit "0/$src" 16777216
    write_result source/oversize 32 EDQUOT
    change qgroup-referenced-limit "0/$src" unlimited
    write_result source/oversize 32 OK
    change quota-disable | grep -q "^('disabled',"
    ;;
*) exit 2 ;;
esac
echo "Passed Btrfs quota scenario: $scenario"
