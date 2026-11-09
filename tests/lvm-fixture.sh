#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced only by the disposable integration tests.
set -eu

skip() { echo "SKIP: $*"; exit 77; }
[ "${MAJORIS_DISKS_RUN_LVM_TESTS:-0}" = 1 ] ||
    skip 'Set MAJORIS_DISKS_RUN_LVM_TESTS=1 inside a dedicated disposable Debian 13 VM'
[ "$(id -u)" = 0 ] || skip 'The isolated fixture requires root'
. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_ID" = 13 ] || skip 'Debian 13 is required'
for tool in losetup lvm pvcreate pvscan pvs vgcreate vgs vgchange vgremove lvcreate lvchange lvs lvremove +    udevadm busctl dmsetup cmp dd truncate mktemp; do
    command -v "$tool" >/dev/null || skip "$tool is unavailable"
done
busctl --system introspect org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager +    org.freedesktop.UDisks2.Manager.LVM2 >/dev/null 2>&1 || skip 'The UDisks LVM2 module is unavailable'
dmsetup version >/dev/null 2>&1 || skip 'Device mapper is unavailable'
losetup --find >/dev/null 2>&1 || skip 'No loop devices are available'

driver=$1
fixture=$(mktemp -d)
vg=majoris_lvm_$(basename "$fixture" | tr -cd '[:alnum:]')
uuid=
fixture_vg_created=0
test -n "$vg"
if vgs --noheadings -o vg_uuid "$vg" >/dev/null 2>&1; then
    rmdir "$fixture"
    echo 'FAIL: the fixture VG name already exists' >&2
    exit 1
fi

loop_for_image() {
    losetup -j "$fixture/pv-$1.img" --list --noheadings --output NAME
}

attach_pv() {
    test -f "$fixture/pv-$1.img" && test -z "$(loop_for_image "$1")" || return 1
    losetup --find --show "$fixture/pv-$1.img"
}

check_pv() {
    test "$2" = "$(loop_for_image "$1")" && test -b "$2"
}

cleanup_lvm_fixture() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    if ! clean_lvm_fixture; then
        echo "FAIL: fixture identity or cleanup uncertain. Retained $fixture" >&2
        exit 1
    fi
    exit "$status"
}

clean_lvm_fixture() {
    if [ "$fixture_vg_created" = 1 ]; then
        test -n "$uuid" || return 1
        for image in "$fixture"/pv-*.img; do
            index=${image##*/pv-}
            index=${index%.img}
            if [ -z "$(loop_for_image "$index")" ]; then
                attach_pv "$index" >/dev/null || return 1
            fi
        done
        udevadm settle || return 1
        name=$(vgs --noheadings -o vg_name --select "vg_uuid=$uuid" | tr -d '[:space:]')
        case "$name" in "$vg"|"${vg}_renamed") ;; *) return 1 ;; esac
        devices=$(pvs --noheadings -o pv_name --select "vg_uuid=$uuid") || return 1
        test -n "$devices" || return 1
        for device in $devices; do
            match=0
            for image in "$fixture"/pv-*.img; do
                index=${image##*/pv-}
                index=${index%.img}
                if check_pv "$index" "$device"; then match=1; break; fi
            done
            test "$match" = 1 || return 1
        done
        vgchange -an "$name" || return 1
        vgremove -y "$name" || return 1
    fi
    for image in "$fixture"/pv-*.img; do
        test -f "$image" || continue
        index=${image##*/pv-}
        index=${index%.img}
        device=$(loop_for_image "$index")
        if [ -n "$device" ]; then
            check_pv "$index" "$device" && losetup -d "$device" || return 1
        fi
        test -z "$(loop_for_image "$index")" || return 1
        rm -- "$image" || return 1
    done
    rm -f -- "$fixture/expected" "$fixture/readback"
    rmdir -- "$fixture"
}
trap cleanup_lvm_fixture EXIT
trap 'exit 1' HUP INT TERM

make_fixture() {
    set --
    for index in $(seq 1 "$pv_count"); do
        truncate -s 512M "$fixture/pv-$index.img"
        device=$(attach_pv "$index")
        check_pv "$index" "$device"
        pvcreate --yes "$device"
        set -- "$@" "$device"
    done
    # Leave the fixture intact if creation succeeds but identity cannot be read.
    fixture_vg_created=1
    vgcreate "$vg" "$@"
    uuid=$(vgs --noheadings -o vg_uuid "$vg" | tr -d '[:space:]')
    test -n "$uuid"
    printf 'Majoris disposable LVM marker %s\n' "$uuid" > "$fixture/expected"
    udevadm settle
}

majoris() {
    udevadm settle
    "$driver" "$fixture" "${current_vg:-$vg}" "$uuid" "$@"
}

check_fixture_lv() {
    test "$(lvs --noheadings -o vg_uuid "$1" | tr -d '[:space:]')" = "$uuid"
    test -b "$1"
}

write_marker() {
    check_fixture_lv "$1"
    dd if="$fixture/expected" of="$1" conv=notrunc,fsync status=none
}

verify_marker() {
    check_fixture_lv "$1"
    dd if="$1" of="$fixture/readback" bs=1 count="$(wc -c < "$fixture/expected")" status=none
    cmp "$fixture/expected" "$fixture/readback"
}

expect_rejection() {
    if majoris "$@"; then
        echo "FAIL: the request unexpectedly succeeded: $*" >&2
        exit 1
    fi
}
