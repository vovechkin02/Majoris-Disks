#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
start_lvm_fixture "$@"
raid1_types=$(lvm segtypes)
init_lvm_fixture "$1"
begin_scenario 'Missing-PV assessment and reconnection (MissingPhysicalVolumes, Structure)'
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
wait_lvm_activation false keeper linear
disconnect_fixture_pv 2 "$p2" "$p1"
majoris assess keeper "$missing_uuid" complete blocked
majoris assess linear "$missing_uuid" affected blocked
expect_rejection 'incomplete or unresolved allocation' cleanup "$missing_uuid"
p2=$(attach_pv 2)
pvscan --cache "$p2"
check_fixture_pv 2 "$p2"
udevadm trigger --action=change --settle "$p2"
majoris assess linear "" complete blocked
lvchange -ay "/dev/$vg/linear"
verify_marker "/dev/$vg/linear"
lvremove --yes "/dev/$vg/linear"
pass_scenario

if printf '%s\n' "$raid1_types" | grep -qx '[[:space:]]*raid1[[:space:]]*'; then
    begin_scenario 'Two-copy RAID1 reconstruction (LogicalVolume.Repair)'
    majoris layout mirror raid1 67108864 "$p1" "$p2"
    lvchange -ay "/dev/$vg/mirror"
    verify_raid_health "/dev/$vg/mirror"
    write_marker "/dev/$vg/mirror"
    vgchange -an "$vg"
    wait_lvm_activation false mirror
    disconnect_fixture_pv 2 "$p2" "$p1"
    lvchange -ay --activationmode degraded "/dev/$vg/mirror"
    wait_lvm_activation true mirror
    majoris assess mirror "$missing_uuid" affected candidate
    verify_marker "/dev/$vg/mirror"
    majoris repair mirror "$missing_uuid" "$p3"
    verify_raid_health "/dev/$vg/mirror"
    verify_marker "/dev/$vg/mirror"
    test "$(lvs --noheadings -o segtype "/dev/$vg/mirror" | tr -d '[:space:]')" = raid1
    vgchange -an "$vg"
    wait_lvm_activation false mirror
    pass_scenario
else
    echo 'SKIP: RAID 1 repair requires the RAID 1 layout'
    disconnect_fixture_pv 2 "$p2" "$p1"
fi

begin_scenario 'Safe missing-PV cleanup (VolumeGroup.RemoveMissingPhysicalVolumes)'
majoris cleanup "$missing_uuid"
majoris assess keeper "" complete blocked
pass_scenario
begin_scenario 'Inactive VG rename (VolumeGroup.Rename)'
vgchange -an "$vg"
wait_lvm_activation false keeper
majoris rename "${vg}_renamed"
current_vg=${vg}_renamed
test "$(vgs --noheadings -o vg_uuid "$current_vg" | tr -d '[:space:]')" = "$uuid"
lvchange -ay "/dev/$current_vg/keeper"
verify_marker "/dev/$current_vg/keeper"
pass_scenario
