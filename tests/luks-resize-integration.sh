#!/bin/sh
set -eu

skip() { echo "Skipped: $*"; exit 77; }
[ "${MAJORIS_TEST_LUKS_RESIZE:-}" = 1 ] || skip "set MAJORIS_TEST_LUKS_RESIZE=1 in an isolated test environment"
[ "$(id -u)" = 0 ] || skip "requires root for disposable loop and dm-crypt fixtures"
for tool in unshare udisksctl udevadm losetup cryptsetup mkfs.ext4 blockdev sha256sum; do
    command -v "$tool" >/dev/null || skip "$tool unavailable"
done
if [ "${2:-}" != private ]; then
    unshare --mount --propagation private true || skip "private mount namespaces unavailable"
    exec unshare --mount --propagation private sh "$0" "$1" private "${2:-mapping}"
fi
layout="${3:-mapping}"
case "$layout" in
    mapping) ;;
    partition) command -v sfdisk >/dev/null || skip "sfdisk unavailable" ;;
    *) exit 2 ;;
esac
[ -c /dev/mapper/control ] || skip "device mapper unavailable"
losetup -f >/dev/null || skip "loop devices unavailable"
udevadm control --ping || skip "udev unavailable"
service=$(realpath "$1")
umask 077
tmp=$(mktemp -d /var/tmp/majoris-luks.resize.XXXXXX)
image="$tmp/resize.img"
name=$(basename "$tmp")
mountpoint="$tmp/mount"
loop=
rule=
created_rules=
cleanup() {
    umount "$mountpoint" 2>/dev/null || :
    if [ -n "$loop" ] && [ "$(losetup --noheadings --output BACK-FILE -- "$loop" 2>/dev/null)" = "$image" ]; then
        if [ -b "/dev/mapper/$name" ]; then cryptsetup close "$name" || :; fi
        losetup -d "$loop" || :
    fi
    if [ -n "$rule" ]; then rm -f -- "$rule"; udevadm control --reload || :; fi
    if [ -n "$created_rules" ]; then rmdir /run/udev/rules.d 2>/dev/null || :; fi
    rm -f -- "$image" "$tmp/key"
    rmdir "$mountpoint" "$tmp" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
mkdir "$mountpoint"
if [ ! -d /run/udev/rules.d ]; then
    mkdir /run/udev/rules.d
    created_rules=1
fi
rule=$(mktemp /run/udev/rules.d/99-majoris-resize-XXXXXX.rules)
{
    printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$image"
    printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*p[0-9]*", ATTRS{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$image"
    printf 'SUBSYSTEM=="block", ENV{DM_NAME}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$name"
} > "$rule"
udevadm control --reload
if [ "$layout" = partition ]; then
    truncate -s 384M "$image"
    printf 'label: gpt\nstart=1MiB, size=256MiB\n' | sfdisk --quiet "$image"
else
    truncate -s 320M "$image"
fi
output=$(LC_ALL=C udisksctl loop-setup --file "$image" --no-user-interaction)
loop=$(printf '%s\n' "$output" | sed -n 's/.* as \(\/dev\/loop[0-9][0-9]*\)\.$/\1/p')
[ -b "$loop" ] && [ "$(losetup --noheadings --output BACK-FILE -- "$loop")" = "$image" ]
target="$loop"
if [ "$layout" = partition ]; then
    udevadm settle
    target="${loop}p1"
    [ -b "$target" ] && [ "$(blockdev --getsize64 "$target")" = 268435456 ]
fi
printf '%s' 'majoris original disposable passphrase' > "$tmp/key"
cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --key-file "$tmp/key" "$target"
cryptsetup open --key-file "$tmp/key" "$target" "$name"
mapping="/dev/mapper/$name"
cryptsetup resize --size 393216 --key-file "$tmp/key" "$name"
mkfs.ext4 -q "$mapping"
mount "$mapping" "$mountpoint"
dd if=/dev/urandom of="$mountpoint/sample" bs=1M count=4 status=none
checksum=$(sha256sum "$mountpoint/sample")
umount "$mountpoint"
udevadm trigger --action=change "/sys/class/block/${target##*/}" "/sys/class/block/$(basename "$(readlink -f "$mapping")")"
udevadm settle
if [ "$layout" = partition ]; then
    set -- 285212672:335544320 201326592:268435456
else
    set -- 251658240 201326592
fi
for size do
    if ! MAJORIS_TEST_LUKS=1 "$service" "$target" "$image" resize "$size"; then
        udisksctl info --block-device "$target" || :
        exit 1
    fi
    [ "$(blockdev --getsize64 "$mapping")" = "${size%%:*}" ]
    if [ "$layout" = partition ]; then [ "$(blockdev --getsize64 "$target")" = "${size#*:}" ]; fi
    mount -o ro "$mapping" "$mountpoint"
    [ "$(sha256sum "$mountpoint/sample")" = "$checksum" ]
    umount "$mountpoint"
done
