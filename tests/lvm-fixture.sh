#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced only by the disposable integration tests.
set -eu
export LC_ALL=C

skip() { echo "SKIP: $*"; exit 77; }
fail() { echo "FAIL: $*" >&2; exit 1; }

lvm_owner() {
    busctl --system call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus GetNameOwner s org.freedesktop.UDisks2 |
        sed -n 's/^s "\(:[^"]*\)"$/\1/p'
}

lvm_module_active() {
    busctl --system --timeout=5s introspect "$lvm_daemon" /org/freedesktop/UDisks2/Manager \
        org.freedesktop.UDisks2.Manager.LVM2 2>/dev/null |
        awk '$1 == ".VolumeGroupCreate" && $2 == "method" { found = 1 } END { exit !found }'
}

ensure_lvm_module() {
    lvm_daemon=$(lvm_owner) && [ -n "$lvm_daemon" ] || fail 'UDisks daemon unavailable'
    manager_path=/org/freedesktop/UDisks2/Manager
    if lvm_module_active; then
        echo "UDisks $lvm_daemon: LVM2 already active"
        return
    fi
    echo "UDisks $lvm_daemon: activating installed LVM2 module"
    busctl --system --timeout=30s call "$lvm_daemon" "$manager_path" \
        org.freedesktop.UDisks2.Manager EnableModule sb lvm2 true ||
        fail "LVM2 module activation failed on $lvm_daemon"
    for attempt in $(seq 1 40); do
        [ "$(lvm_owner)" = "$lvm_daemon" ] || fail 'UDisks owner changed during LVM2 activation'
        if lvm_module_active; then
            echo "UDisks $lvm_daemon: Manager.LVM2 published"
            return
        fi
        sleep 0.25
    done
    fail "LVM2 activation returned but Manager.LVM2 was not published by $lvm_daemon"
}

restart_lvm_fixture_daemon() {
    previous_daemon=$(lvm_owner)
    [ -n "$previous_daemon" ] || fail 'UDisks daemon unavailable before restart'
    systemctl restart udisks2
    for attempt in $(seq 1 40); do
        restarted_daemon=$(lvm_owner 2>/dev/null)
        if [ -n "$restarted_daemon" ] && [ "$restarted_daemon" != "$previous_daemon" ]; then
            echo "UDisks owner changed from $previous_daemon to $restarted_daemon"
            return
        fi
        sleep 0.25
    done
    fail 'UDisks did not publish a new owner after restart'
}

require_lvm_tools() {
    for tool in losetup lvm pvcreate pvremove pvscan pvs vgcreate vgs vgchange vgremove \
        lvcreate lvchange lvs lvremove udevadm busctl dmsetup python3 cmp dd truncate mktemp stat sha256sum
    do
        command -v "$tool" >/dev/null 2>&1 || skip "$tool is unavailable"
    done
    dmsetup version >/dev/null 2>&1 || skip 'Device mapper is unavailable'
    losetup --find >/dev/null 2>&1 || skip 'No loop devices are available'
    [ -n "$(lvm_owner)" ] || skip 'UDisks daemon is unavailable'
    [ "$(dpkg-query -W -f='${db:Status-Status}' udisks2-lvm2 2>/dev/null)" = installed ] ||
        skip 'The Debian udisks2-lvm2 package is missing'
    ensure_lvm_module
}

start_lvm_fixture() {
    [ "${MAJORIS_DISKS_RUN_LVM_TESTS:-0}" = 1 ] ||
        skip 'Set MAJORIS_DISKS_RUN_LVM_TESTS=1 inside a dedicated disposable Debian 13 VM'
    [ "$(id -u)" = 0 ] || skip 'The isolated fixture requires root'
    [ -r /etc/os-release ] || skip 'Debian 13 is required'
    . /etc/os-release
    [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] || skip 'Debian 13 is required'
    [ "$(systemd-detect-virt --vm)" = qemu ] || skip 'A dedicated QEMU guest is required'
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
        echo 'UDisks state at fixture exit:'
        lvm_owner
        busctl --system --timeout=5s introspect org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager || :
        busctl --system --timeout=5s tree org.freedesktop.UDisks2 || :
        dmsetup ls --tree || :
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
                # Clear the verified fixture's PV label before releasing the loop
                # number. UDisks can otherwise retain the previous PV interface
                # when the same block path is immediately reused by another test.
                pvremove --yes "$device" || return 1
                udevadm trigger --action=change --settle "$device" || return 1
            fi
            losetup -d "$device" || return 1
            udevadm settle || return 1
            retire_stale_lvm_loop "$device" || return 1
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

retire_stale_lvm_loop() {
    loop_name=${1##*/}
    case "$loop_name" in loop[0-9]*) ;; *) return 1 ;; esac
    object=/org/freedesktop/UDisks2/block_devices/$loop_name
    daemon=$(lvm_owner) || return 1
    test -n "$daemon" || return 1
    group=$(busctl --system --timeout=5s get-property "$daemon" "$object" \
        org.freedesktop.UDisks2.PhysicalVolume VolumeGroup 2>/dev/null) || return 0
    case "$group" in
        'o "/"') return 0 ;;
        "o \"/org/freedesktop/UDisks2/lvm/$vg\""|"o \"/org/freedesktop/UDisks2/lvm/${vg}_renamed\"") ;;
        *) echo "Unexpected PV association on $loop_name: $group" >&2; return 1 ;;
    esac
    echo "Retiring unbound fixture $loop_name with stale UDisks PV association $group"
    # LOOP_CTL_REMOVE refuses a bound or open device. This removes the stale
    # UDisks object for this fixture index before another suite reuses it.
    python3 - "$loop_name" <<'PY' || return 1
import fcntl
import pathlib
import re
import sys

name = sys.argv[1]
if not re.fullmatch(r"loop[0-9]+", name):
    raise SystemExit("Invalid fixture loop name")
device = pathlib.Path("/sys/class/block") / name
if (device / "size").read_text().strip() != "0" or (device / "loop").exists() or any((device / "holders").iterdir()):
    raise SystemExit("Fixture loop is still bound or held")
with open("/dev/loop-control", "rb+", buffering=0) as control:
    fcntl.ioctl(control, 0x4C81, int(name[4:]))  # LOOP_CTL_REMOVE
PY
    udevadm settle || return 1
    test ! -e "/sys/class/block/$loop_name"
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
    ensure_lvm_module
    group_path=/org/freedesktop/UDisks2/lvm/${current_vg:-$vg}
    for volume in "$@"; do
        lv_device=/dev/${current_vg:-$vg}/$volume
        lv_uuid=$(lvs --noheadings -o lv_uuid "${current_vg:-$vg}/$volume" | tr -d '[:space:]')
        [ -n "$lv_uuid" ] || fail "LVM metadata has no logical volume $volume"
        ready=0
        for attempt in $(seq 1 40); do
            [ "$(lvm_owner)" = "$lvm_daemon" ] || fail 'UDisks owner changed during LV discovery'
            busctl --system --timeout=5s call "$lvm_daemon" "$group_path" \
                org.freedesktop.UDisks2.VolumeGroup Poll >/dev/null 2>&1 || :
            group_id=$(busctl --system get-property "$lvm_daemon" "$group_path" \
                org.freedesktop.UDisks2.VolumeGroup UUID 2>/dev/null) || group_id=
            volume_id=$(busctl --system get-property "$lvm_daemon" "$group_path/$volume" \
                org.freedesktop.UDisks2.LogicalVolume UUID 2>/dev/null) || volume_id=
            [ -z "$group_id" ] || [ "$group_id" = "s \"$uuid\"" ] || fail "Fixture VG identity changed: $group_id"
            [ -z "$volume_id" ] || [ "$volume_id" = "s \"$lv_uuid\"" ] || fail "Fixture LV identity changed: $volume_id"
            if [ -z "$group_id" ] || [ -z "$volume_id" ]; then sleep 0.5; continue; fi
            active=$(busctl --system get-property "$lvm_daemon" "$group_path/$volume" \
                org.freedesktop.UDisks2.LogicalVolume Active 2>/dev/null) || active=
            mapping=$(busctl --system get-property "$lvm_daemon" "$group_path/$volume" \
                org.freedesktop.UDisks2.LogicalVolume BlockDevice 2>/dev/null) || mapping=
            if { [ "$expected_active" = false ] && [ "$mapping" = 'o "/"' ]; } ||
                { [ "$expected_active" = true ] && [ -n "$mapping" ] && [ "$mapping" != 'o "/"' ]; }; then
                if [ "$active" != "b $expected_active" ]; then sleep 0.5; continue; fi
                if [ "$expected_active" = true ]; then
                    block_path=$(printf '%s\n' "$mapping" | sed -n 's/^o "\(\/org\/freedesktop\/UDisks2\/block_devices\/dm_2d[0-9]*\)"$/\1/p')
                    [ -n "$block_path" ] || fail "Unexpected device-mapper object: $mapping"
                    number=$(busctl --system get-property "$lvm_daemon" "$block_path" \
                        org.freedesktop.UDisks2.Block DeviceNumber 2>/dev/null) || number=
                    backlink=$(busctl --system get-property "$lvm_daemon" "$block_path" \
                        org.freedesktop.UDisks2.Block.LVM2 LogicalVolume 2>/dev/null) || backlink=
                    expected_number=$(stat -Lc '%r' "$lv_device" 2>/dev/null) || expected_number=
                    if [ -z "$expected_number" ] || [ "$number" != "t $expected_number" ] ||
                        [ "$backlink" != "o \"$group_path/$volume\"" ]; then sleep 0.5; continue; fi
                fi
                [ "$(lvm_owner)" = "$lvm_daemon" ] || fail 'UDisks owner changed after LV discovery'
                ready=1
                break
            fi
            sleep 0.5
        done
        test "$ready" = 1 || fail "UDisks $lvm_daemon discovery incomplete for $volume ($lv_uuid), expected Active=$expected_active"
        echo "UDisks $lvm_daemon: $group_path/$volume $lv_uuid $active $mapping"
    done
}

wait_lvm_absent() {
    absent_path="/org/freedesktop/UDisks2/lvm/${current_vg:-$vg}/$1"
    udevadm settle
    for attempt in $(seq 1 40); do
        [ "$(lvm_owner)" = "$lvm_daemon" ] || fail 'UDisks owner changed while observing LV removal'
        busctl --system --timeout=5s call "$lvm_daemon" "${absent_path%/*}" \
            org.freedesktop.UDisks2.VolumeGroup Poll >/dev/null 2>&1 || :
        if ! busctl --system --timeout=5s get-property "$lvm_daemon" "$absent_path" \
            org.freedesktop.UDisks2.LogicalVolume UUID >/dev/null 2>&1; then
            [ "$(lvm_owner)" = "$lvm_daemon" ] || fail 'UDisks owner changed while observing LV removal'
            return
        fi
        sleep 0.25
    done
    fail "The removed LV remains visible at $absent_path"
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
