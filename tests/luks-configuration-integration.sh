#!/bin/sh
# Opt-in in a dedicated test VM. The private UDisks instance sees an overlay
# of /etc and separate runtime and persistent state directories.
set -eu

skip() { echo "Skipped: $*"; exit 77; }
[ "${MAJORIS_TEST_CRYPTTAB:-}" = 1 ] || skip "set MAJORIS_TEST_CRYPTTAB=1 in a dedicated test VM"
[ "$(id -u)" = 0 ] || skip "requires root for isolated UDisks and loop setup"
for tool in unshare dbus-run-session busctl mountpoint udevadm losetup cryptsetup mkfs.ext4 findmnt; do
    command -v "$tool" >/dev/null || skip "$tool unavailable"
done
udisksd=/usr/libexec/udisks2/udisksd
[ -x "$udisksd" ] || skip "Debian UDisks daemon unavailable"
if [ "${3:-}" != private ]; then
    unshare --mount --propagation private true || skip "private mount namespaces unavailable"
    exec unshare --mount --propagation private dbus-run-session -- sh "$0" "$1" "$2" private
fi
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || skip "private test bus unavailable"
[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] ||
    skip "the configuration fixture requires a private mount namespace"
export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
service=$(realpath "$1")
inspector=$(realpath "$2")
umask 077
tmp=$(mktemp -d /var/tmp/majoris-luks.crypttab.XXXXXX)
name=$(basename "$tmp")
image="$tmp/$name.img"
loop=
rule=
daemon=
created_rules=
mapping=
mount_path="$tmp/mount"
bind_path="$tmp/bind"
cleanup() {
    if [ -n "$mapping" ]; then
        umount "$bind_path" 2>/dev/null || :
        umount "$mount_path" 2>/dev/null || :
        cryptsetup close "$name" || :
    fi
    if [ -n "$daemon" ]; then kill "$daemon" 2>/dev/null || :; wait "$daemon" 2>/dev/null || :; fi
    if [ -n "$loop" ] && [ "$(losetup --noheadings --output BACK-FILE -- "$loop" 2>/dev/null)" = "$image" ]; then
        losetup -d "$loop" || :
    fi
    if [ -n "$rule" ]; then rm -f -- "$rule"; udevadm control --reload || :; fi
    if [ -n "$created_rules" ]; then rmdir /run/udev/rules.d 2>/dev/null || :; fi
    if [ -f "$tmp/mounted-state" ]; then umount /var/lib/udisks2 || return; fi
    if [ -f "$tmp/mounted-run" ]; then umount /run/udisks2 || return; fi
    if [ -f "$tmp/mounted-etc" ]; then umount /etc || return; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
mkdir "$tmp/upper" "$tmp/work" "$tmp/run" "$tmp/state"
mount -t overlay overlay -o "lowerdir=/etc,upperdir=$tmp/upper,workdir=$tmp/work" /etc ||
    skip "private configuration overlay unavailable"
touch "$tmp/mounted-etc"
mountpoint -q /etc
touch /etc/majoris-private-crypttab
rm -f -- /etc/crypttab
touch /etc/crypttab
if [ -e /etc/luks-keys ] || [ -L /etc/luks-keys ]; then skip "dedicated fixture requires a fresh key directory"; fi
# Exercise the installed boundary's checks against the private configuration.
mkdir -m 0700 /etc/luks-keys
chmod 0600 /etc/crypttab
key=/etc/luks-keys/inspector-test
printf '%s' 'fixture bytes' >"$key"
printf 'inspector-test UUID=fixture %s nofail,vendor-option\n' "$key" > /etc/crypttab
inspect_key() {
    "$inspector" inspector-test inspector-test UUID=fixture nofail,vendor-option "$key" "$key"
}
expect_inspector_status() {
    expected=$1
    actual=0
    inspect_key >/dev/null || actual=$?
    [ "$actual" = "$expected" ]
}
before_identity=$(inspect_key)
printf 'foreign UUID=foreign %s none\n' "$key" >> /etc/crypttab
expect_inspector_status 13
sed -i '/^foreign /d' /etc/crypttab
ln "$key" "$key.alias"
expect_inspector_status 11
rm -- "$key.alias"
mv -- "$key" "$key.original"
ln -s -- "$key.original" "$key"
expect_inspector_status 11
rm -- "$key"
expect_inspector_status 14
printf '%s' 'replacement bytes' >"$key"
[ "$(inspect_key)" != "$before_identity" ]
chmod 0777 /etc/luks-keys
expect_inspector_status 11
rm -- "$key" "$key.original"
rmdir /etc/luks-keys
: > /etc/crypttab

mount --bind "$tmp/run" /run/udisks2
touch "$tmp/mounted-run"
mount --bind "$tmp/state" /var/lib/udisks2
touch "$tmp/mounted-state"
if [ ! -d /run/udev/rules.d ]; then mkdir /run/udev/rules.d; created_rules=1; fi
rule=$(mktemp /run/udev/rules.d/99-majoris-crypttab-XXXXXX.rules)
{
    printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$image"
    printf 'SUBSYSTEM=="block", ENV{DM_NAME}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' "$name"
} > "$rule"
udevadm control --reload
truncate -s 80M "$image"
loop=$(losetup --find --show -- "$image")
[ "$(losetup --noheadings --output BACK-FILE -- "$loop")" = "$image" ]
printf '%s' 'majoris original disposable passphrase' |
    cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --key-file - "$loop"
udevadm trigger --action=change "/sys/class/block/${loop##*/}"
udevadm settle
"$udisksd" --disable-modules >"$tmp/daemon.log" 2>&1 &
daemon=$!
for attempt in 1 2 3 4 5; do
    if busctl --address="$DBUS_SYSTEM_BUS_ADDRESS" status org.freedesktop.UDisks2 >/dev/null 2>&1; then break; fi
    sleep 1
done
if ! MAJORIS_TEST_LUKS=1 "$service" "$loop" "$image" configuration unused; then
    cat "$tmp/daemon.log" /etc/crypttab
    udisksctl info --block-device "$loop" || :
    exit 1
fi
cryptsetup open --test-passphrase --key-file "/etc/luks-keys/$name" "$loop"
printf '%s' 'majoris original disposable passphrase' | cryptsetup open --test-passphrase --key-file - "$loop"
MAJORIS_TEST_LUKS=1 "$service" "$loop" "$image" remove-configuration unused
[ ! -s /etc/crypttab ] && [ ! -e "/etc/luks-keys/$name" ]

printf '%s' 'majoris original disposable passphrase' | cryptsetup open --key-file - "$loop" "$name"
mapping="/dev/mapper/$name"
mkfs.ext4 -q "$mapping"
mkdir "$mount_path" "$bind_path"
printf '%s %s ext4 noauto,nodev,nosuid 0 0\n' "$mapping" "$mount_path" >> /etc/fstab
udevadm trigger --action=change "/sys/class/block/$(basename "$(readlink -f "$mapping")")"
udevadm settle
udisksctl mount --block-device "$mapping" --no-user-interaction
before=$(findmnt -n -o SOURCE,TARGET,OPTIONS --mountpoint "$mount_path")
MAJORIS_TEST_LUKS=1 "$service" "$loop" "$image" restore-mount "$mount_path"
[ "$(findmnt -n -o SOURCE,TARGET,OPTIONS --mountpoint "$mount_path")" = "$before" ]
mkdir "$mount_path/subdir"
mount --bind "$mount_path/subdir" "$bind_path"
MAJORIS_TEST_LUKS=1 "$service" "$loop" "$image" refuse-bind-mount "$mount_path"
mountpoint -q "$mount_path" && mountpoint -q "$bind_path"
echo "Passed: encrypted fstab mount restoration and bind-mount refusal"
