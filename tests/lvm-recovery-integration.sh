#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
pv_count=3
make_fixture
p1=$(loop_for_image 1)
p2=$(loop_for_image 2)
p3=$(loop_for_image 3)
missing_uuid=$(pvs --noheadings -o pv_uuid "$p2" | tr -d '[:space:]')
test -n "$missing_uuid"
lvcreate --yes -L 64M -n keeper "$vg" "$p1"
lvcreate --yes -L 64M -n linear "$vg" "$p2"
write_marker "/dev/$vg/keeper"
write_marker "/dev/$vg/linear"
vgchange -an "$vg"
check_pv 2 "$p2"
losetup -d "$p2"
udevadm settle
test -z "$(loop_for_image 2)"
majoris assess keeper "$missing_uuid" complete blocked
majoris assess linear "$missing_uuid" affected blocked
expect_rejection cleanup "$missing_uuid"
p2=$(attach_pv 2)
check_pv 2 "$p2"
pvscan --cache "$p2"
majoris assess linear "" complete blocked
lvchange -ay "/dev/$vg/linear"
verify_marker "/dev/$vg/linear"
lvremove --yes "/dev/$vg/linear"

if lvm segtypes | grep -qx '[[:space:]]*raid1[[:space:]]*'; then
    majoris layout mirror raid1 67108864 "$p1" "$p2"
    lvchange -ay "/dev/$vg/mirror"
    write_marker "/dev/$vg/mirror"
    vgchange -an "$vg"
    check_pv 2 "$p2"
    losetup -d "$p2"
    udevadm settle
    test -z "$(loop_for_image 2)"
    lvchange -ay --activationmode degraded "/dev/$vg/mirror"
    majoris assess mirror "$missing_uuid" affected candidate
    majoris repair mirror "$missing_uuid" "$p3"
    verify_marker "/dev/$vg/mirror"
    test "$(lvs --noheadings -o segtype "/dev/$vg/mirror" | tr -d '[:space:]')" = raid1
    vgchange -an "$vg"
else
    echo 'SKIP: RAID 1 repair requires the RAID 1 layout'
    check_pv 2 "$p2"
    losetup -d "$p2"
    udevadm settle
    test -z "$(loop_for_image 2)"
fi

majoris cleanup "$missing_uuid"
majoris assess keeper "" complete blocked
majoris rename "${vg}_renamed"
current_vg=${vg}_renamed
test "$(vgs --noheadings -o vg_uuid "$current_vg" | tr -d '[:space:]')" = "$uuid"
lvchange -ay "/dev/$current_vg/keeper"
verify_marker "/dev/$current_vg/keeper"
