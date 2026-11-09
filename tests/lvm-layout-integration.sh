#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
pv_count=4
make_fixture
p1=$(loop_for_image 1)
p2=$(loop_for_image 2)
p3=$(loop_for_image 3)
p4=$(loop_for_image 4)

exercise_layout() {
    layout=$1
    shift
    if ! lvm segtypes | grep -qx "[[:space:]]*$layout[[:space:]]*"; then
        echo "SKIP: $layout is unavailable"
        return
    fi
    majoris layout "$layout" "$layout" 67108864 "$@"
    lv=/dev/$vg/$layout
    lvchange -ay "$lv"
    test "$(lvs --noheadings -o segtype "$lv" | tr -d '[:space:]')" = "$layout"
    write_marker "$lv"
    lvchange -an "$lv"
    lvchange -ay "$lv"
    verify_marker "$lv"
    lvchange -an "$lv"
}

exercise_layout linear "$p1"
exercise_layout raid0 "$p1" "$p2"
exercise_layout raid1 "$p1" "$p2"
exercise_layout raid5 "$p1" "$p2" "$p3"
exercise_layout raid6 "$p1" "$p2" "$p3" "$p4"
exercise_layout raid10 "$p1" "$p2" "$p3" "$p4"
expect_rejection layout too_few raid6 67108864 "$p1" "$p2"
expect_rejection layout duplicate raid1 67108864 "$p1" "$p1"
expect_rejection layout too_large raid1 1073741824 "$p1" "$p2"
expect_rejection layout unavailable linear 67108864 /dev/majoris-fixture-nonexistent
test -z "$(lvs --noheadings -o lv_name "$vg" | grep -E 'too_few|duplicate|too_large|unavailable' || :)"
