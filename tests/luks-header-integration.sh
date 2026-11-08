#!/bin/sh
# Opt-in only. Uses a private mount namespace and uniquely owned loop files.
set -eu

skip() { echo "Skipped: $*"; exit 77; }
[ "${MAJORIS_TEST_LUKS:-}" = 1 ] || skip "set MAJORIS_TEST_LUKS=1 in an isolated Linux test environment"
[ "$(id -u)" -eq 0 ] || skip "requires root for disposable loop and dm-crypt fixtures"
for tool in unshare losetup cryptsetup mkfs.ext4 mount umount python3; do
    command -v "$tool" >/dev/null || skip "$tool unavailable"
done
worker=$(realpath "${1:?provide the built Majoris LUKS worker}")
[ -x "$worker" ] || skip "Majoris header worker unavailable"
service=${2:-}
if [ -n "$service" ]; then
    service=$(realpath "$service")
    command -v udisksctl >/dev/null && command -v udevadm >/dev/null || skip "UDisks or udev unavailable"
fi
if [ "${3:-}" != private ]; then
    unshare --mount --propagation private true 2>/dev/null || skip "private mount namespaces unavailable"
    exec unshare --mount --propagation private sh "$0" "$worker" "$service" private
fi
[ -c /dev/mapper/control ] || skip "device mapper unavailable"
losetup --find >/dev/null 2>&1 || skip "no free usable loop device"

umask 077
tmp=$(mktemp -d /var/tmp/majoris-luks.XXXXXX)
mountpoint="$tmp/mount"
mkdir "$mountpoint"
base="majoris-luks-$(basename "$tmp")"
one= two= raw= fat= fat_mount= rule= rules_directory_created=
verify_loop() (
    image=$2
    [ -b "$1" ] && [ "$(losetup --noheadings --output BACK-FILE -- "$1")" = "$image" ]
)
cleanup() {
    umount "$mountpoint" 2>/dev/null || :
    if [ -n "$fat_mount" ]; then
        umount "$fat_mount" 2>/dev/null || :
        rmdir "$fat_mount" 2>/dev/null || :
    fi
    for name in "$base-1" "$base-2"; do
        if cryptsetup status "$name" 2>/dev/null | grep -Fq "$name is active"; then
            cryptsetup close "$name" || :
        fi
    done
    for item in "one:$one" "two:$two" "raw:$raw" "fat:$fat"; do
        image="$tmp/${item%%:*}.img"; loop=${item#*:}
        if [ -n "$loop" ] && verify_loop "$loop" "$image"; then losetup -d "$loop" || :; fi
    done
    if [ -n "$rule" ]; then
        rm -f -- "$rule"
        udevadm control --reload || :
    fi
    if [ -n "$rules_directory_created" ]; then
        rmdir "$rules_directory_created" 2>/dev/null || :
    fi
    rm -f -- "$tmp/"*.img "$tmp/"*.header "$tmp/"*.key "$tmp/"*.ticket "$tmp/"*.json
    rmdir "$mountpoint" "$tmp" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

new_loop() {
    truncate -s 80M "$tmp/$1.img"
    if [ "$1" = one ] && [ -n "$service" ]; then
        output=$(LC_ALL=C udisksctl loop-setup --file "$tmp/$1.img" --no-user-interaction)
        printf '%s\n' "$output" | sed -n 's/.* as \(\/dev\/loop[0-9][0-9]*\)\.$/\1/p'
    else
        losetup --find --show -- "$tmp/$1.img"
    fi
}
one=$(new_loop one)
two=$(new_loop two)
raw=$(new_loop raw)
for item in "one:$one" "two:$two" "raw:$raw"; do
    verify_loop "${item#*:}" "$tmp/${item%%:*}.img" || exit 1
done
if [ -n "${MAJORIS_TEST_FAT_FORMATTER:-}" ]; then
    fat=$(new_loop fat)
    verify_loop "$fat" "$tmp/fat.img"
    "$MAJORIS_TEST_FAT_FORMATTER" -F 32 "$fat"
    fat_mount="$tmp/fat"
    mkdir "$fat_mount"
    mount -t vfat -o nodev,nosuid,noexec "$fat" "$fat_mount"
    python3 - "$fat_mount" <<'PYFAT'
import errno
import os
import tempfile
import sys

with tempfile.NamedTemporaryFile(dir=sys.argv[1]) as file:
    try:
        os.setxattr(file.name, "user.majoris-test", b"xattr")
    except OSError as error:
        if error.errno != errno.EOPNOTSUPP:
            raise
    else:
        raise AssertionError("Portability fixture unexpectedly supports user xattrs")
PYFAT
fi
if [ -n "$service" ]; then
    # UDisks conservatively treats loop devices as system storage by default.
    # Classify only this exact disposable backing file as non-system storage.
    if [ ! -d /run/udev/rules.d ]; then
        mkdir /run/udev/rules.d
        rules_directory_created=/run/udev/rules.d
    fi
    rule=$(mktemp /run/udev/rules.d/99-majoris-luks-XXXXXX.rules)
    printf 'SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ATTR{loop/backing_file}=="%s", ENV{UDISKS_SYSTEM}="0", ENV{UDISKS_AUTO}="0"\n' \
        "$tmp/one.img" > "$rule"
    udevadm control --reload
fi

# Replicate the production descriptor contract. The loop association is
# checked again on the opened descriptor via LOOP_GET_STATUS64.
run() (
    target=$1 image=$2 operation=$3 path=$4 ticket=$5 mode=$6
    verify_loop "$target" "$tmp/$image.img" || return 1
    python3 - "$target" "$tmp/$image.img" "$worker" "$operation" "$path" "loop:$image" "$ticket" "$mode" <<'PY'
import fcntl
import os
import struct
import sys

dev, image, worker, operation, path, binding, ticket, mode = sys.argv[1:]
flags = os.O_RDWR | os.O_EXCL if operation == "restore" or operation.endswith("-keyslot") else os.O_RDONLY
try:
    fd = os.open(dev, flags | os.O_NOFOLLOW)
except OSError as error:
    print(error, file=sys.stderr)
    sys.exit(2)
status = fcntl.ioctl(fd, 0x4C05, bytes(232))  # LOOP_GET_STATUS64
devnum, inode = struct.unpack_from("=QQ", status)
fixture = os.stat(image)
if (devnum, inode) != (fixture.st_dev, fixture.st_ino):
    sys.exit("Loop descriptor no longer refers to the fixture")
if fd != 3:
    os.dup2(fd, 3)
    os.close(fd)
os.set_inheritable(3, True)
args = [worker, operation, path, binding, ticket, "", mode]
if operation.endswith("-keyslot"):
    args.extend([os.environ.get("first_file", ""), os.environ.get("second_file", "")])
if os.environ.get("MAJORIS_LUKS_TEST_FAULT"):
    os.environ["LD_PRELOAD"] = os.environ["MAJORIS_TEST_FAULT_LIBRARY"]
os.execv(worker, args)
PY
)
reject() {
    if "$@"; then echo "Failed: operation unexpectedly succeeded" >&2; exit 1
    else [ "$?" -eq 2 ] || exit 1
    fi
}

run_service() {
    verify_loop "$one" "$tmp/one.img" || return 1
    udevadm trigger --action=change --sysname-match="${one##*/}"
    udevadm settle --timeout=10
    "$service" "$one" "$tmp/one.img" "$1" "$2"
}

printf 'majoris original disposable passphrase' > "$tmp/old.key"
printf 'majoris replacement disposable passphrase' > "$tmp/new.key"
printf 'invalid' > "$tmp/invalid.header"
for version in 1 2; do
    name="$base-$version"
    header="$tmp/luks$version.header"
    verify_loop "$one" "$tmp/one.img"
    cryptsetup luksFormat --batch-mode --type "luks$version" --pbkdf pbkdf2 --iter-time 20 --key-file "$tmp/old.key" "$one"
    cryptsetup open --key-file "$tmp/old.key" "$one" "$name"
    mkfs.ext4 -q -b 4096 "/dev/mapper/$name" 12000
    # Write a ciphertext sample beyond the intentionally smaller filesystem.
    sectors=$(blockdev --getsz "/dev/mapper/$name")
    dd if=/dev/zero of="/dev/mapper/$name" bs=512 seek="$((sectors - 16))" count=16 conv=fsync status=none
    mount "/dev/mapper/$name" "$mountpoint"
    printf 'majoris test data %s\n' "$version" > "$mountpoint/data"
    umount "$mountpoint"

    info=$(run "$one" one inspect "" "" normal)
    printf '%s\n' "$info" | grep "^LUKS$version "
    ticket=$(printf '%s\n' "$info" | sed -n 2p)
    [ "$(run "$one" one backup "$header" "$ticket" normal | tail -1)" = device-identity ]
    [ "$(stat -c %a "$header")" = 600 ]
    cryptsetup luksDump "$header" >/dev/null
    reject run "$one" one backup "$header" "$ticket" normal
    ln -s "$header" "$tmp/link.header"
    reject run "$one" one preview "$tmp/link.header" "" normal
    reject run "$one" one backup "$tmp/link.header" "$ticket" normal
    rm -- "$tmp/link.header"
    reject run "$one" one preview "$tmp/invalid.header" "" normal
    # Use FAT when an explicit formatter is available. The fallback copies
    # just the bytes to exercise transport without preserved file attributes.
    portable_dir=${fat_mount:-$tmp}
    cat "$header" > "$portable_dir/portable.header"
    cat "$header.majoris.json" > "$portable_dir/portable.header.majoris.json"
    rm -- "$header" "$header.majoris.json"
    if [ -n "$fat_mount" ]; then
        sync -f "$fat_mount"
        [ "$(run "$one" one preview "$fat_mount/portable.header" "" normal | sed -n 4p)" = checksummed ]
        cp -- "$fat_mount/portable.header" "$fat_mount/portable.header.majoris.json" "$tmp"
        echo "Passed: LUKS$version backup and manifest transferred through xattr-free FAT"
    fi
    header="$tmp/portable.header"
    cat "$header" > "$tmp/altered.header"
    cp "$header.majoris.json" "$tmp/altered.header.majoris.json"
    python3 - "$tmp/altered.header" <<'PYTEST'
import sys
with open(sys.argv[1], "r+b") as file:
    file.seek(-1, 2)
    value = file.read(1)[0]
    file.seek(-1, 2)
    file.write(bytes([value ^ 1]))
PYTEST
    reject run "$one" one preview "$tmp/altered.header" "" normal
    rm -- "$tmp/altered.header" "$tmp/altered.header.majoris.json"
    preview=$(run "$one" one preview "$header" "" normal | sed -n 2p)
    reject run "$one" one restore "$header" "$preview" normal
    # Deliberately overwrite the exact tail region the old recovery proof sampled.
    mount "/dev/mapper/$name" "$mountpoint"
    printf 'modified after backup %s\n' "$version" > "$mountpoint/updated"
    umount "$mountpoint"
    dd if=/dev/urandom of="/dev/mapper/$name" bs=512 seek="$((sectors - 16))" count=16 conv=fsync status=none
    cryptsetup close "$name"
    if [ -n "$service" ]; then
        run_service backup "$tmp/service$version.header"
        if [ "$version" = 1 ] && command -v runuser >/dev/null && command -v busctl >/dev/null; then
            object="/org/freedesktop/UDisks2/block_devices/${one##*/}"
            if denial=$(LC_ALL=C runuser -u nobody -- busctl --system --allow-interactive-authorization=no \
                call org.freedesktop.UDisks2 "$object" org.freedesktop.UDisks2.Block OpenDevice 'sa{sv}' r 0 2>&1); then
                echo "Failed: unauthenticated descriptor access was allowed" >&2
                exit 1
            fi
            printf '%s\n' "$denial" | grep -Ei 'not authorized|authentication|permission denied'
            echo "Passed: UDisks refused unauthenticated descriptor access"
        fi
    fi

    verify_loop "$one" "$tmp/one.img"
    cryptsetup luksChangeKey --pbkdf pbkdf2 --iter-time 20 --key-file "$tmp/old.key" "$one" "$tmp/new.key"
    reject run "$one" one restore "$header" "$preview" normal
    preview=$(run "$one" one preview "$header" "" normal | sed -n 2p)
    if [ -n "$service" ]; then
        run_service restore "$header"
    else
        run "$one" one restore "$header" "$preview" normal
    fi
    if cryptsetup open --test-passphrase --key-file "$tmp/new.key" "$one"; then exit 1; fi
    cryptsetup open --key-file "$tmp/old.key" "$one" "$name"
    mount -o ro "/dev/mapper/$name" "$mountpoint"
    grep -Fx "majoris test data $version" "$mountpoint/data"
    umount "$mountpoint"
    cryptsetup close "$name"

    verify_loop "$two" "$tmp/two.img"
    cryptsetup luksFormat --batch-mode --type "luks$version" --pbkdf pbkdf2 --iter-time 20 --key-file "$tmp/old.key" "$two"
    before=$(sha256sum "$two")
    reject run "$two" two preview "$header" "" normal
    [ "$before" = "$(sha256sum "$two")" ]
    reject run "$two" two restore "$header" "$preview" normal
    uuid=$(cryptsetup luksUUID "$one")
    other=$((3 - version))
    for mismatch in version offset keysize; do
        verify_loop "$two" "$tmp/two.img"
        case "$mismatch" in
            version) set -- --type "luks$other" ;;
            offset) set -- --type "luks$version" --offset 65536 ;;
            keysize) set -- --type "luks$version" --key-size 256 ;;
        esac
        cryptsetup luksFormat --batch-mode --uuid "$uuid" --pbkdf pbkdf2 --iter-time 20 \
            --key-file "$tmp/old.key" "$@" "$two"
        reject run "$two" two preview "$header" "" normal
    done
    # A byte-identical clone still has a different kernel device identity.
    verify_loop "$one" "$tmp/one.img"
    verify_loop "$two" "$tmp/two.img"
    dd if="$one" of="$two" bs=1M conv=fsync status=none
    current=$(run "$one" one preview "$header" "" normal | sed -n 2p)
    reject run "$two" two restore "$header" "$current" normal

    if [ -n "${MAJORIS_TEST_FAULT_LIBRARY:-}" ]; then
        for fault in short-write interrupted-write fsync readback; do
            fixture_ticket=$(run "$one" one preview "$header" "" normal | sed -n 2p)
            status=0
            MAJORIS_LUKS_TEST_FAULT=$fault run "$one" one restore "$header" "$fixture_ticket" normal \
                > "$tmp/fault.ticket" 2>&1 || status=$?
            grep -Fx 'phase:write-header' "$tmp/fault.ticket"
            case "$fault" in
                interrupted-write) [ "$status" -eq 137 ] ;;
                *) [ "$status" -eq 3 ] ;;
            esac
            verify_loop "$one" "$tmp/one.img"
            cryptsetup luksHeaderRestore --batch-mode --header-backup-file "$header" "$one"
        done
        echo "Passed: LUKS$version short write, interrupted write, fsync and readback faults"
    fi

    # Raw backups remain inspectable and compatible with a readable live header.
    cryptsetup luksHeaderBackup --header-backup-file "$tmp/raw-backup.header" "$one"
    raw_review=$(run "$one" one preview "$tmp/raw-backup.header" "" normal)
    [ "$(printf '%s\n' "$raw_review" | sed -n 4p)" = structure-only ]
    run "$one" one restore "$tmp/raw-backup.header" "$(printf '%s\n' "$raw_review" | sed -n 2p)" normal
    python3 - "$tmp/raw-backup.header" "$one" <<'PYLEGACY'
import hashlib
import os
import subprocess
import sys

header, device = sys.argv[1:]
with open(header, "rb") as f:
    os.setxattr(header, "user.majoris.luks-sha256", hashlib.file_digest(f, "sha256").hexdigest().encode())
os.setxattr(header, "user.majoris.luks-source-size", subprocess.check_output(
    ["blockdev", "--getsize64", device]).strip())
os.setxattr(header, "user.majoris.luks-source", b"0" * 64)
PYLEGACY
    [ "$(run "$one" one preview "$tmp/raw-backup.header" "" normal | sed -n 4p)" = checksummed ]

    # Reattach the same backing inode to obtain a different kernel disk sequence.
    if [ -z "$service" ]; then
        verify_loop "$one" "$tmp/one.img"
        previous_sequence=$(blockdev --getdiskseq "$one")
        losetup -d "$one"
        one=$(losetup --find --show -- "$tmp/one.img")
        verify_loop "$one" "$tmp/one.img"
        [ "$(blockdev --getdiskseq "$one")" != "$previous_sequence" ]
    fi
    verify_loop "$one" "$tmp/one.img"
    bytes=$(stat -c %s "$header")
    dd if=/dev/zero of="$one" bs=512 count="$((bytes / 512))" conv=fsync status=none
    if cryptsetup open --test-passphrase --key-file "$tmp/old.key" "$one"; then exit 1; fi
    reject run "$one" one preview "$header" "" normal
    advanced=$(run "$one" one preview "$header" "" advanced)
    [ "$(printf '%s\n' "$advanced" | sed -n 3p)" = device-identity ]
    [ "$(run "$one" one preview "$tmp/raw-backup.header" "" advanced | sed -n 3p)" = unestablished ]
    reject run "$one" one restore "$tmp/raw-backup.header" "" advanced
    [ "$(run "$raw" raw preview "$header" "" advanced | sed -n 3p)" = unestablished ]
    reject run "$raw" raw restore "$header" "" advanced
    if [ -n "$service" ]; then
        # Use a service-generated backup to exercise its source binding.
        run_service advanced "$tmp/service$version.header"
    else
        run "$one" one restore "$header" "$(printf '%s\n' "$advanced" | sed -n 2p)" advanced
    fi
    cryptsetup open --key-file "$tmp/old.key" "$one" "$name"
    mount -o ro "/dev/mapper/$name" "$mountpoint"
    grep -Fx "majoris test data $version" "$mountpoint/data"
    umount "$mountpoint"
    cryptsetup close "$name"
    if [ -n "$service" ]; then run_service credentials "$header"; fi

    slot_ticket() { run "$one" one list-keyslots "" "" normal | sed -n 2p; }
    first_file="$tmp/old.key"; second_file="$tmp/new.key"; export first_file second_file
    initial=$(slot_ticket)
    reject run "$one" one remove-keyslot "0:0" "$initial" normal
    second_file="$tmp/missing.key"
    reject run "$one" one add-keyslot "-1:-1" "$initial" normal
    ln -s "$tmp/new.key" "$tmp/symlink.key"
    second_file="$tmp/symlink.key"
    reject run "$one" one add-keyslot "-1:-1" "$initial" normal
    rm -- "$tmp/symlink.key"
    second_file="$tmp/new.key"
    run "$one" one add-keyslot "-1:-1" "$initial" normal
    reject run "$one" one add-keyslot "-1:-1" "$initial" normal
    cryptsetup open --test-passphrase --key-slot 0 --key-file "$first_file" "$one"
    cryptsetup open --test-passphrase --key-slot 1 --key-file "$second_file" "$one"

    if [ "$version" = 2 ]; then
        printf '%s\n' '{"type":"systemd-fido2","keyslots":["1"]}' > "$tmp/token.json"
        cryptsetup token import --json-file "$tmp/token.json" "$one"
        run "$one" one list-keyslots "" "" normal | grep -E '^token [0-9]+ systemd-fido2 recognised 1$'
        first_file="$tmp/new.key"; second_file="$tmp/old.key"
        reject run "$one" one remove-keyslot "1:0" "$(slot_ticket)" normal
        cryptsetup token remove --token-id 0 "$one"
    fi

    first_file="$tmp/old.key"; second_file="$tmp/new.key"
    run "$one" one remove-keyslot "0:1" "$(slot_ticket)" normal
    if cryptsetup open --test-passphrase --key-file "$first_file" "$one"; then exit 1; fi
    cryptsetup open --test-passphrase --key-file "$second_file" "$one"
    printf 'binary\000credential\377' > "$tmp/binary.key"
    first_file="$tmp/new.key"; second_file="$tmp/binary.key"
    run "$one" one change-keyslot "1:-1" "$(slot_ticket)" normal
    cryptsetup open --key-file "$second_file" "$one" "$name"
    mount -o ro "/dev/mapper/$name" "$mountpoint"
    grep -Fx "majoris test data $version" "$mountpoint/data"
    grep -Fx "modified after backup $version" "$mountpoint/updated"
    umount "$mountpoint"
    cryptsetup close "$name"
    if cryptsetup open --test-passphrase --key-file "$first_file" "$one"; then exit 1; fi
    echo "Passed: LUKS$version keyslot lifecycle, binary keyfile and data readback"
    rm -- "$tmp/raw-backup.header"
    if [ "$version" = 1 ]; then rm -- "$header" "$header.majoris.json"; fi
    echo "Passed: LUKS$version backup, restore, data readback, damaged recovery and rejections"
done

verify_loop "$raw" "$tmp/raw.img"
mkfs.ext4 -q "$raw"
mount "$raw" "$mountpoint"
reject run "$raw" raw restore "$header" "$preview" advanced
umount "$mountpoint"
before=$(sha256sum "$raw")
reject run "$raw" raw preview "$header" "" advanced
[ "$before" = "$(sha256sum "$raw")" ]
echo "Passed: mounted device and unrelated filesystem rejection"
