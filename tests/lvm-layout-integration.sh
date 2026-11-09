#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
start_lvm_fixture "$@"
types=$(lvm segtypes)
init_lvm_fixture "$1"
begin_scenario 'Layout fixture setup'
pv_count=5
make_fixture
p1=$(loop_for_image 1)
p2=$(loop_for_image 2)
p3=$(loop_for_image 3)
p4=$(loop_for_image 4)
p5=$(loop_for_image 5)

exercised=0
exercise_layout() {
    layout=$1
    bytes=$2
    shift 2
    if ! printf '%s\n' "$types" | grep -qx "[[:space:]]*$layout[[:space:]]*"; then
        echo "SKIP: $layout is unavailable"
        return
    fi
    begin_scenario "$layout (VolumeGroup.CreatePlainVolumeWithLayout)"
    majoris layout "$layout" "$layout" "$bytes" "$@"
    lv=/dev/$vg/$layout
    lvchange -ay "$lv"
    test "$(lvs --noheadings -o segtype "$lv" | tr -d '[:space:]')" = "$layout"
    test "$(lvs --noheadings --units b --nosuffix -o lv_size "$lv" | tr -d '[:space:]')" = "$bytes"
    case "$layout" in raid1|raid5|raid6|raid10) verify_raid_health "$lv";; esac
    write_marker "$lv"
    lvchange -an "$lv"
    wait_lvm_activation false "$layout"
    lvchange -ay "$lv"
    wait_lvm_activation true "$layout"
    verify_marker "$lv"
    lvchange -an "$lv"
    wait_lvm_activation false "$layout"
    pass_scenario
    exercised=$((exercised + 1))
}

exercise_layout linear 67108864 "$p1"
exercise_layout raid0 67108864 "$p1" "$p2"
exercise_layout raid1 67108864 "$p1" "$p2"
exercise_layout raid5 67108864 "$p1" "$p2" "$p3"
exercise_layout raid6 75497472 "$p1" "$p2" "$p3" "$p4" "$p5"
exercise_layout raid10 67108864 "$p1" "$p2" "$p3" "$p4"
test "$exercised" -gt 0 || fail 'No layout was exercised'
begin_scenario 'Reject invalid layout placements'
if printf '%s\n' "$types" | grep -qx '[[:space:]]*raid6[[:space:]]*'; then
    expect_rejection 'physical-volume count or extent alignment' layout too_few raid6 67108864 "$p1" "$p2" "$p3" "$p4"
fi
if printf '%s\n' "$types" | grep -qx '[[:space:]]*raid1[[:space:]]*'; then
    expect_rejection 'Select distinct physical devices' layout duplicate raid1 67108864 "$p1" "$p1"
    expect_rejection 'too few free extents' layout too_large raid1 1073741824 "$p1" "$p2"
fi
expect_rejection 'requested fixture PV is unavailable' layout unavailable linear 67108864 /dev/majoris-fixture-nonexistent
expect_rejection 'Enter a valid logical-volume name' layout 'bad/name' linear 67108864 "$p1"
expect_rejection 'already has this name' layout linear linear 67108864 "$p1"
expect_rejection 'does not advertise this layout' layout unsupported invalid-layout 67108864 "$p1"
names=$(lvs --noheadings -o lv_name "$vg")
if printf '%s\n' "$names" | grep -Eq 'too_few|duplicate|too_large|unavailable|unsupported'; then
    fail 'A rejected layout exists'
fi
pass_scenario
