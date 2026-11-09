#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced only by the disposable integration tests.
set -eu

skip() { echo "SKIP: $*"; exit 77; }
fail() { echo "FAIL: $*" >&2; exit 1; }

require_lvm_tools() {
    for tool in losetup lvm pvcreate pvscan pvs vgcreate vgs vgchange vgremove \
        lvcreate lvchange lvs lvremove udevadm busctl dmsetup cmp dd truncate mktemp stat sha256sum
    do
        command -v "$tool" >/dev/null 2>&1 || skip "$tool is unavailable"
    done
    busctl --system introspect org.freedesktop.UDisks2 \
        /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager.LVM2 \
        >/dev/null 2>&1 || skip 'The UDisks LVM2 module is unavailable'
    dmsetup version >/dev/null 2>&1 || skip 'Device mapper is unavailable'
    losetup --find >/dev/null 2>&1 || skip 'No loop devices are available'
}

start_lvm_fixture() {
    [ "${MAJORIS_DISKS_RUN_LVM_TESTS:-0}" = 1 ] ||
        skip 'Set MAJORIS_DISKS_RUN_LVM_TESTS=1 inside a dedicated disposable Debian 13 VM'
    [ "$(id -u)" = 0 ] || skip 'The isolated fixture requires root'
    [ -r /etc/os-release ] || skip 'Debian 13 is required'
    . /etc/os-release
    [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] || skip 'Debian 13 is required'
    require_lvm_tools
    test -x "${1:-}" || fail "Fixture driver is unavailable: ${1:-missing argument}"
}

init_lvm_fixture() {
    driver=$1
    fixture=$(mktemp -d /tmp/majoris-lvm.XXXXXXXXXX)
    vg=majoris_lvm_$(basename "$fixture" | tr -cd '[:alnum:]')
    current_vg=$vg
    uuid=
    fixture_vg_created=0
    rule_created=0
    names=$(vgs --noheadings -o vg_name) || fail "Cannot enumerate VGs. Retained $fixture"
    for name in $names; do
        if [ "$name" = "$vg" ]; then
            rmdir "$fixture"
            fail 'The fixture VG name already exists'
        fi
    done
    trap cleanup_lvm_fixture EXIT
    trap 'exit 1' HUP INT TERM
    # UDisks classifies unmanaged loop devices as system devices by default.
    # Override that hint only for this fixture's private images and mappings.
    rule=/run/udev/rules.d/99-$vg.rules
    mkdir -p /run/udev/rules.d
    (set -C; printf '%s\n' \
        "SUBSYSTEM==\"block\", KERNEL==\"loop[0-9]*\", ATTR{loop/backing_file}==\"$fixture/pv-*.img\", ENV{UDISKS_SYSTEM}=\"0\"" \
        "SUBSYSTEM==\"block\", KERNEL==\"dm-[0-9]*\", ENV{DM_VG_NAME}==\"$vg|${vg}_renamed\", ENV{UDISKS_SYSTEM}=\"0\"" > "$rule")
    rule_created=1
    udevadm control --reload
}

loop_for_image() {
    losetup -j "$fixture/pv-$1.img" --list --noheadings --output NAME
}

check_image() {
    image_path=$fixture/pv-$1.img
    test -f "$image_path" && test ! -L "$image_path" &&
        image_id=$(stat -c '%d:%i:%s' "$image_path") &&
        test "$image_id" = "$(cat "$fixture/pv-$1.identity")"
}

attach_pv() {
    check_image "$1" || return 1
    attached=$(loop_for_image "$1") || return 1
    test -z "$attached" || return 1
    losetup --find --show "$fixture/pv-$1.img"
}

check_pv() {
    check_image "$1" && test -b "$2" && test "$2" = "$(loop_for_image "$1")"
}

check_fixture_pv() {
    check_pv "$1" "$2" &&
        actual=$(pvs --noheadings -o pv_uuid "$2") &&
        test "$(printf '%s' "$actual" | tr -d '[:space:]')" = "$(cat "$fixture/pv-$1.uuid")"
}

cleanup_lvm_fixture() {
    status=$?
    trap - EXIT
    trap 'echo "FAIL: cleanup interrupted. Retained $fixture" >&2; exit 1' HUP INT TERM
    set +e
    if [ "$status" -ne 0 ]; then
        echo "FAIL: ${scenario:-fixture setup} (status $status)" >&2
        report_lvm_fixture
        [ "$status" != 77 ] || status=1
    fi
    if ! clean_lvm_fixture; then
        echo "FAIL: fixture identity or cleanup uncertain. Retained $fixture" >&2
        status=1
    fi
    if [ "${rule_created:-0}" = 1 ]; then
        rm -- "$rule" && udevadm control --reload || status=1
    fi
    exit "$status"
}

clean_lvm_fixture() {
    if [ "$fixture_vg_created" = 1 ]; then
        test -n "$uuid" || return 1
        count=$(vgs --noheadings -o vg_missing_pv_count --select "vg_uuid=$uuid") || return 1
        missing_count=$(printf '%s' "$count" | tr -d '[:space:]')
        case "$missing_count" in ''|*[!0-9]*) return 1 ;; esac
        fixture_devices=
        for image in "$fixture"/pv-*.img; do
            index=${image##*/pv-}
            index=${index%.img}
            check_image "$index" || return 1
            device=$(loop_for_image "$index") || return 1
            if [ -z "$device" ]; then
                # A completed missing-record cleanup may leave stale VG
                # metadata on the removed image. Keep that image detached.
                [ "$missing_count" -gt 0 ] || continue
                device=$(attach_pv "$index") || return 1
                pvscan --cache "$device" || return 1
            fi
            check_fixture_pv "$index" "$device" || return 1
            fixture_devices=${fixture_devices:+$fixture_devices,}$device
        done
        udevadm settle || return 1
        name=$(vgs --noheadings -o vg_name --select "vg_uuid=$uuid") || return 1
        name=$(printf '%s' "$name" | tr -d '[:space:]')
        case "$name" in "$vg"|"${vg}_renamed") ;; *) return 1 ;; esac
        count=$(vgs --noheadings -o vg_missing_pv_count --select "vg_uuid=$uuid") || return 1
        test "$(printf '%s' "$count" | tr -d '[:space:]')" = 0 || return 1
        devices=$(pvs --noheadings -o pv_name --select "vg_uuid=$uuid") || return 1
        test -n "$devices" || return 1
        for device in $devices; do
            match=0
            for image in "$fixture"/pv-*.img; do
                index=${image##*/pv-}
                index=${index%.img}
                if check_fixture_pv "$index" "$device"; then match=1; break; fi
            done
            test "$match" = 1 || return 1
        done
        vgchange --devices "$fixture_devices" -an --select "vg_uuid=$uuid" || return 1
        vgremove --devices "$fixture_devices" -y --select "vg_uuid=$uuid" || return 1
        remaining=$(vgs --noheadings -o vg_uuid --select "vg_uuid=$uuid") || return 1
        test -z "$remaining" || return 1
    fi
    for image in "$fixture"/pv-*.img; do
        if [ ! -e "$image" ] && [ ! -L "$image" ]; then continue; fi
        index=${image##*/pv-}
        index=${index%.img}
        check_image "$index" || return 1
        device=$(loop_for_image "$index") || return 1
        if [ -n "$device" ]; then
            check_pv "$index" "$device" || return 1
            owner=$(pvs --noheadings -o vg_uuid --select "pv_name=$device") || return 1
            test -z "$(printf '%s' "$owner" | tr -d '[:space:]')" || return 1
            if [ -f "$fixture/pv-$index.uuid" ]; then
                check_fixture_pv "$index" "$device" || return 1
            fi
            losetup -d "$device" || return 1
        fi
        attached=$(loop_for_image "$index") || return 1
        test -z "$attached" || return 1
        rm -- "$image" || return 1
        rm -f -- "$fixture/pv-$index.uuid" || return 1
        rm -- "$fixture/pv-$index.identity" || return 1
    done
    rm -f -- "$fixture/expected" "$fixture/readback"
    rmdir -- "$fixture"
}
make_fixture() {
    set --
    for index in $(seq 1 "$pv_count"); do
        truncate -s 512M "$fixture/pv-$index.img"
        stat -c '%d:%i:%s' "$fixture/pv-$index.img" > "$fixture/pv-$index.identity"
        device=$(attach_pv "$index")
        check_pv "$index" "$device"
        pvcreate --yes "$device"
        pv_uuid=$(pvs --noheadings -o pv_uuid "$device")
        pv_uuid=$(printf '%s' "$pv_uuid" | tr -d '[:space:]')
        test -n "$pv_uuid"
        printf '%s\n' "$pv_uuid" > "$fixture/pv-$index.uuid"
        set -- "$@" "$device"
    done
    # Leave the fixture intact if creation succeeds but identity cannot be read.
    fixture_vg_created=1
    vgcreate --setautoactivation n "$vg" "$@"
    uuid=$(vgs --noheadings -o vg_uuid "$vg")
    uuid=$(printf '%s' "$uuid" | tr -d '[:space:]')
    test -n "$uuid"
    dd if=/dev/urandom of="$fixture/expected" bs=64K count=1 iflag=fullblock status=none
    # LVM metadata writes to an already attached loop do not necessarily emit
    # the block change event UDisks needs to discover a new PV.
    udevadm trigger --action=change --settle "$@"
    udevadm settle
}

majoris() {
    echo "ATTEMPT: $*"
    udevadm settle || fail 'udev did not settle'
    "$driver" "$fixture" "${current_vg:-$vg}" "$uuid" "$@"
}

wait_lvm_activation() {
    expected_active=$1
    shift
    udevadm settle
    group_path=/org/freedesktop/UDisks2/lvm/${current_vg:-$vg}
    for volume in "$@"; do
        ready=0
        for attempt in $(seq 1 40); do
            busctl --system call org.freedesktop.UDisks2 "$group_path" \
                org.freedesktop.UDisks2.VolumeGroup Poll >/dev/null 2>&1 || :
            active=$(busctl --system get-property org.freedesktop.UDisks2 "$group_path/$volume" \
                org.freedesktop.UDisks2.LogicalVolume Active 2>/dev/null) || active=
            mapping=$(busctl --system get-property org.freedesktop.UDisks2 "$group_path/$volume" \
                org.freedesktop.UDisks2.LogicalVolume BlockDevice 2>/dev/null) || mapping=
            if { [ "$expected_active" = false ] && [ "$mapping" = 'o "/"' ]; } ||
                { [ "$expected_active" = true ] && [ -n "$mapping" ] && [ "$mapping" != 'o "/"' ]; }; then
                if [ "$active" != "b $expected_active" ]; then sleep 0.5; continue; fi
                ready=1
                break
            fi
            sleep 0.5
        done
        test "$ready" = 1 || fail "UDisks did not confirm $volume Active=$expected_active ($active, $mapping)"
    done
}

disconnect_fixture_pv() {
    check_fixture_pv "$1" "$2"
    losetup -d "$2"
    udevadm settle
    attached=$(loop_for_image "$1")
    test -z "$attached" || fail "Fixture PV $1 did not detach"
    if [ -b "$2" ] && ! losetup "$2" >/dev/null 2>&1; then
        udevadm trigger --action=change --settle "$2"
    fi
    check_fixture_pv 1 "$3"
    udevadm trigger --action=change --settle "$3"
}

report_lvm_fixture() {
    test -n "$uuid" || return 0
    vgs --select "vg_uuid=$uuid" -o vg_name,vg_uuid,pv_count,lv_count &&
        lvs -a --select "vg_uuid=$uuid" -o lv_name,lv_uuid,lv_size,segtype,devices,lv_attr,lv_health_status,copy_percent,cache_mode,cache_dirty_blocks,pool_lv,pool_lv_uuid,lv_check_needed
}

begin_scenario() {
    scenario=$1
    echo "ATTEMPT: $scenario"
}

pass_scenario() {
    report_lvm_fixture
    echo "PASS: $scenario"
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
    dd if="$1" of="$fixture/readback" bs=64K count=1 iflag=fullblock status=none
    cmp "$fixture/expected" "$fixture/readback"
    sha256sum "$fixture/readback"
}

verify_raid_health() {
    check_fixture_lv "$1"
    attrs=$(lvs --noheadings -o lv_attr "$1" | tr -d '[:space:]')
    case "$attrs" in ????????-?) ;; *) fail "RAID health flags: $attrs";; esac
    health=$(lvs --noheadings -o lv_health_status "$1")
    test -z "$(printf '%s' "$health" | tr -d '[:space:]')"
    sync=$(lvs --noheadings -o copy_percent "$1" | tr -d '[:space:]')
    printf '%s\n' "$sync" | grep -Eq '^100([.]0+)?$'
}

expect_rejection() {
    status=0
    majoris reject "$@" || status=$?
    test "$status" = 0 || fail "Could not verify expected rejection: $*"
}
