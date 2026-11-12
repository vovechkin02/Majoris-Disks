#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

skip() { echo "SKIP: $*"; exit 77; }
[ "${MAJORIS_DISKS_RUN_LOOP_TESTS:-0}" = 1 ] || skip 'Set MAJORIS_DISKS_RUN_LOOP_TESTS=1 in the disposable guest'
[ "$(id -u)" = 0 ] || skip 'Root is required for the isolated loop fixture'
. /etc/os-release
[ "$ID:$VERSION_ID" = debian:13 ] && [ "$(systemd-detect-virt --vm)" = qemu ] ||
    skip 'This fixture requires a disposable Debian 13 QEMU guest'
if [ "$3" = restart ]; then
    [ "${MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS:-0}" = 1 ] ||
        skip 'Set MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS=1 in the disposable guest'
fi
for tool in busctl losetup sfdisk mkfs.ext4 udevadm findmnt; do
    command -v "$tool" >/dev/null || skip "$tool is missing"
done
losetup --find >/dev/null || skip 'No loop devices are available'
test -x "$1" && test -r "$2"
driver=$1
library=$2
mode=$3
fixture=$(mktemp -d /var/tmp/majoris-loop-fault.XXXXXXXX)
image=$fixture/fixture.img
log=$fixture/events
export XDG_STATE_HOME="$fixture/state"
remove_journal() {
    directory=$XDG_STATE_HOME/majoris-disks/imaging
    if [ ! -d "$directory" ]; then return; fi
    if [ "$mode" = setup ] || [ "$mode" = substitute ]; then
        set -- "$directory"/*.ini
        [ "$#" = 1 ] && [ -f "$1" ] && [ ! -L "$1" ]
        grep -Fxq "target=$image" "$1"
        rm -- "$1"
    fi
    rmdir -- "$directory" "$XDG_STATE_HOME/majoris-disks" "$XDG_STATE_HOME"
}
trap 'status=$?; if [ "$status" != 0 ]; then
    echo "FAIL: retained loop fault evidence in $fixture" >&2
    cat "$log" >&2
    losetup -j "$image" >&2
fi' EXIT
touch "$log"
truncate -s 64M "$image"
mkfs.ext4 -q -F -L MAJORIS_LOOP -E offset=1048576 "$image" 16384
printf 'label: gpt\nstart=2048, size=32768, type=L\n' | sfdisk "$image"
identity=$(stat -c '%d:%i' "$image")
checksum=$(sha256sum "$image")
echo "Fixture $image device:inode $identity; $checksum"

if [ "$mode" = reuse ] || [ "$mode" = substitute ]; then
    replacement=$image.replacement
    cp -- "$image" "$replacement"
    printf 'replacement' | dd of="$replacement" bs=1 seek=65536 conv=notrunc status=none
    replacement_identity=$(stat -c '%d:%i' "$replacement")
    replacement_checksum=$(sha256sum "$replacement")
fi
if [ "$mode" = reuse ]; then
    "$driver" --loop-fault reuse "$image"
    [ -z "$(losetup -j "$image" -ln --output NAME)" ]
    [ -z "$(losetup -j "$replacement" -ln --output NAME)" ]
    [ "$(stat -c '%d:%i' "$replacement")" = "$replacement_identity" ]
    [ "$(sha256sum "$replacement")" = "$replacement_checksum" ]
    [ "$(stat -c '%d:%i' "$image")" = "$identity" ]
    [ "$(sha256sum "$image")" = "$checksum" ]
    remove_journal
    rm -- "$replacement" "$image" "$log"
    rmdir -- "$fixture"
    echo 'PASS: replacement at the same loop device number survived a stale detach'
    exit 0
fi

env LD_PRELOAD="$library" MAJORIS_LOOP_FAULT_IMAGE="$image" MAJORIS_LOOP_FAULT_LOG="$log" \
    MAJORIS_LOOP_FAULT_MODE="$mode" "$driver" --loop-fault "$mode" "$image"
cat "$log"
case "$mode" in
    setup|restart|substitute) method=LoopSetup ;;
    delete) method=Loop.Delete ;;
    *) exit 1 ;;
esac
[ "$(grep -c "^dispatch $method " "$log")" = 1 ]
[ "$(grep -c "^accepted $method " "$log")" = 1 ]
backing_image=$image
if [ "$mode" = substitute ]; then
    [ "$(grep -c '^substituted LoopSetup ' "$log")" = 1 ]
    [ "$(stat -c '%d:%i' "$image")" = "$replacement_identity" ]
    [ "$(sha256sum "$image" | cut -d' ' -f1)" = "${replacement_checksum%% *}" ]
    [ -z "$(losetup -j "$image" -ln --output NAME)" ]
    backing_image=$image.original
fi
[ "$(stat -c '%d:%i' "$backing_image")" = "$identity" ]
[ "$(sha256sum "$backing_image" | cut -d' ' -f1)" = "${checksum%% *}" ]
if [ "$mode" != delete ]; then
    object=$(awk '/^accepted LoopSetup / {print $4}' "$log")
    name=${object##*/}
    mapping=$(losetup -j "$backing_image" -ln --output NAME)
    [ "$mapping" = "/dev/$name" ]
    sequence=$(cat "/sys/class/block/$name/diskseq")
    [ -n "$sequence" ] && [ "$sequence" = "$(awk '/^diskseq / {print $3}' "$log")" ]
    number=$(cat "/sys/class/block/$name/dev")
    [ "$(cat "/sys/class/block/$name/loop/backing_file")" = "$backing_image" ]
    busctl --system get-property org.freedesktop.UDisks2 "$object" org.freedesktop.UDisks2.Loop BackingFile
    echo "Verified $object, device $number, diskseq $sequence, backing $backing_image"
    if [ "$mode" = setup ]; then "$driver" --loop-fault recover-setup "$image"; fi
    if [ "$mode" = restart ]; then
        old_owner=$(awk '/^accepted LoopSetup / {print $3}' "$log")
        new_owner=$(busctl --system call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetNameOwner s org.freedesktop.UDisks2)
        [ "$new_owner" != "s \"$old_owner\"" ]
        echo "Restart changed UDisks owner from $old_owner to $new_owner"
        partition=${name}p1
        signature=
        for attempt in $(seq 1 40); do
            signature=$(busctl --system get-property org.freedesktop.UDisks2 \
                "/org/freedesktop/UDisks2/block_devices/$partition" org.freedesktop.UDisks2.Block IdType 2>/dev/null) ||
                signature=
            if [ "$signature" = 's "ext4"' ]; then break; fi
            sleep 0.25
        done
        [ "$signature" = 's "ext4"' ]
        expected=$(dd if="$image" bs=1M skip=1 count=16 status=none | sha256sum)
        actual=$(dd if="/dev/$partition" bs=1M count=16 status=none | sha256sum)
        [ "$actual" = "$expected" ]
        echo "Verified $partition ext4 payload $actual"
    fi
    # The observer is a new process and may have no session-owned loop token.
    # Release only the exact read-only fixture mapping independently verified above.
    [ "$(stat -c '%d:%i' "$backing_image")" = "$identity" ]
    [ "$(losetup -ln --output BACK-INO "/dev/$name" | tr -d '[:space:]')" = "${identity#*:}" ]
    [ "$(cat "/sys/class/block/$name/diskseq")" = "$sequence" ]
    [ "$(cat "/sys/class/block/$name/loop/backing_file")" = "$backing_image" ]
    for node in "/sys/class/block/$name" "/sys/class/block/$name"/"$name"p*; do
        [ -e "$node" ] || continue
        [ -z "$(ls -A "$node/holders")" ]
        if findmnt -rn --source "/dev/${node##*/}" >/dev/null; then exit 1; fi
    done
    losetup -d "/dev/$name"
    udevadm settle
fi
[ -z "$(losetup -j "$image" -ln --output NAME)" ]
[ -z "$(losetup -j "$backing_image" -ln --output NAME)" ]
remove_journal
if [ "$mode" = substitute ]; then rm -- "$backing_image"; fi
rm -- "$image" "$log"
rmdir -- "$fixture"
echo "PASS: $mode with one accepted $method dispatch"
