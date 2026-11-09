#!/bin/sh
# Opt-in fixture. UDisks sees private configuration and state.
set -eu
skip() { printf 'Skipped: %s\n' "$*"; exit 77; }
[ "${MAJORIS_TEST_LUKS_RESTORATION:-}" = 1 ] || skip "set MAJORIS_TEST_LUKS_RESTORATION=1 in a dedicated Debian test environment"
[ "$(id -u)" = 0 ] || skip "requires root for disposable loop and LUKS setup"
for command in unshare dbus-run-session busctl udevadm cryptsetup losetup mkfs.ext4 mountpoint dmsetup; do
    command -v "$command" >/dev/null || skip "$command unavailable"
done
udisksd=/usr/libexec/udisks2/udisksd
[ -x "$udisksd" ] || skip "UDisks daemon unavailable"
if [ "${2:-}" != private ]; then
    unshare --pid --fork --mount --mount-proc --propagation private true || skip "isolated namespaces unavailable"
    exec unshare --pid --fork --mount --mount-proc --propagation private dbus-run-session -- sh "$0" "$1" private
fi
[ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ] || exit 2
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || exit 2
[ -c /dev/mapper/control ] || skip "device mapper unavailable"
losetup -f >/dev/null || skip "loop devices unavailable"
udevadm control --ping || skip "udev is unavailable"
export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
service=$(realpath "$1")
umask 077
fixture=$(mktemp -d /mnt/majoris-luks-restoration.XXXXXX)
image=$fixture/storage.img
first=$fixture/first
second=$fixture/second
bind=$fixture/bind
backup=$fixture/header
loop=
name=
daemon=
rule=
created_rules=
cleanup() {
    if [ -n "$daemon" ]; then kill "$daemon" 2>/dev/null || :; wait "$daemon" 2>/dev/null || :; fi
    umount "$bind" 2>/dev/null || :
    umount "$second" 2>/dev/null || :
    umount "$first" 2>/dev/null || :
    if [ -n "$loop" ] && [ "$(losetup -n -O BACK-FILE -- "$loop" 2>/dev/null)" = "$image" ]; then
        if [ -n "$name" ] && [ -b "/dev/mapper/$name" ] &&
            [ "$(cryptsetup status "$name" | awk '$1 == "device:" { print $2 }')" = "$loop" ]; then
            cryptsetup close "$name" || :
        fi
        losetup -d "$loop"
    fi
    if [ -n "$rule" ]; then rm -f -- "$rule"; udevadm control --reload || :; fi
    if [ -n "$created_rules" ]; then rmdir /run/udev/rules.d 2>/dev/null || :; fi
    if mountpoint -q /etc && [ -e /etc/majoris-luks-restoration-fixture ]; then umount /etc || return; fi
    if mountpoint -q /run/udisks2 && [ -e /run/udisks2/majoris-fixture ]; then umount /run/udisks2 || return; fi
    if mountpoint -q /var/lib/udisks2 && [ -e /var/lib/udisks2/majoris-fixture ]; then umount /var/lib/udisks2 || return; fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
mkdir "$first" "$second" "$bind" "$fixture/upper" "$fixture/work" "$fixture/run" "$fixture/state"
mount -t overlay overlay -o "lowerdir=/etc,upperdir=$fixture/upper,workdir=$fixture/work" /etc ||
    skip "private configuration overlay unavailable"
touch /etc/majoris-luks-restoration-fixture
rm -f -- /etc/crypttab /etc/fstab
: > /etc/crypttab
: > /etc/fstab
[ -d /run/udisks2 ] && [ -d /var/lib/udisks2 ] || skip "UDisks runtime/state directories unavailable"
touch "$fixture/run/majoris-fixture" "$fixture/state/majoris-fixture"
mount --bind "$fixture/run" /run/udisks2
mount --bind "$fixture/state" /var/lib/udisks2
truncate -s 96M "$image"
loop=$(losetup --find --show -- "$image")
[ "$(losetup -n -O BACK-FILE -- "$loop")" = "$image" ]
printf '%s' 'majoris original disposable passphrase' > "$fixture/key"
cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --key-file "$fixture/key" "$loop"
uuid=$(cryptsetup luksUUID "$loop")
name=luks-$uuid
mapping=/dev/mapper/$name
[ ! -e "$mapping" ]
if [ ! -d /run/udev/rules.d ]; then
    mkdir /run/udev/rules.d
    created_rules=1
fi
rule=$(mktemp /run/udev/rules.d/99-majoris-restoration-XXXXXX.rules)
{
    printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$image"
    printf 'SUBSYSTEM=="block", ENV{DM_NAME}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$name"
} > "$rule"
udevadm control --reload
cryptsetup luksHeaderBackup "$loop" --header-backup-file "$backup"
cryptsetup open --key-file "$fixture/key" "$loop" "$name"
mkfs.ext4 -q "$mapping"
udevadm trigger --action=change "/sys/class/block/${loop##*/}" "/sys/class/block/$(basename "$(readlink -f "$mapping")")"
udevadm settle
"$udisksd" --disable-modules >"$fixture/daemon.log" 2>&1 &
daemon=$!
for attempt in 1 2 3 4 5; do
    if busctl --address="$DBUS_SYSTEM_BUS_ADDRESS" status org.freedesktop.UDisks2 >/dev/null 2>&1; then break; fi
    sleep 1
done
mounts() {
    mount -o nodev,nosuid "$mapping" "$first"
    mkdir -p "$first/projects"
    printf 'encrypted fixture\n' > "$first/projects/sample"
    mount -o nodev,nosuid "$mapping" "$second"
    mount --bind "$first/projects" "$bind"
}
run_service() {
    if ! MAJORIS_TEST_LUKS=1 "$service" "$loop" "$image" "$1" "$backup"; then
        cat "$fixture/daemon.log"
        udisksctl info --block-device "$loop" || :
        if [ -b "$mapping" ]; then udisksctl info --block-device "$mapping" || :; fi
        exit 1
    fi
}
mounts
run_service mapping-restoration
[ "$(cat "$bind/sample")" = 'encrypted fixture' ]
mountpoint -q "$first"
mountpoint -q "$second"
run_service mapping-restoration-rebind
[ "$(cat "$bind/sample")" = 'encrypted fixture' ]
run_service mapping-restoration-keyfile
[ "$(cat "$bind/sample")" = 'encrypted fixture' ]
run_service mapping-restoration-cancel
[ ! -e "$mapping" ]
if mountpoint -q "$first"; then exit 1; fi
if mountpoint -q "$second"; then exit 1; fi
if mountpoint -q "$bind"; then exit 1; fi
cryptsetup open --key-file "$fixture/key" "$loop" "$name"
udevadm settle
mounts
run_service mapping-restoration-wrong
[ ! -e "$mapping" ]
cryptsetup open --key-file "$fixture/key" "$loop" "$name"
udevadm settle
mounts
run_service mapping-restoration-conflict
[ ! -e "$mapping" ]
cryptsetup open --key-file "$fixture/key" "$loop" "$name"
udevadm settle
mounts
run_service mapping-restoration-changed
[ ! -e "$mapping" ]
[ "$(cryptsetup luksUUID "$loop")" != "$uuid" ]
cryptsetup --batch-mode luksUUID "$loop" --uuid "$uuid"
cryptsetup open --key-file "$fixture/key" "$loop" "$name"
udevadm trigger --action=change "/sys/class/block/${loop##*/}"
udevadm settle
mounts
run_service mapping-restoration-partial
mountpoint -q "$first"
mountpoint -q "$second"
[ -L "$bind" ]
rm -- "$bind"
mv -- "$fixture/saved-bind" "$bind"
mount --bind "$first/projects" "$bind"
if [ -e /etc/luks-keys ] || [ -L /etc/luks-keys ]; then skip "managed credential fixture requires a fresh private key directory"; fi
mkdir -m 0700 /etc/luks-keys
cp -- "$fixture/key" "/etc/luks-keys/$name"
printf '%s UUID=%s /etc/luks-keys/%s luks,noauto\n' "$name" "$uuid" "$name" > /etc/crypttab
udevadm trigger --action=change "/sys/class/block/${loop##*/}"
udevadm settle
run_service mapping-restoration-managed
[ "$(cat "$bind/sample")" = 'encrypted fixture' ]
mountpoint -q "$first"
mountpoint -q "$second"
echo "Passed: Majoris LUKS header maintenance, interactive and managed reopening, cancellation, incorrect credential, and dependent mount restoration"
