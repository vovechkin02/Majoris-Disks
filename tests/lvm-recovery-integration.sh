#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
restart_stage=${2:-none}
case "$restart_stage" in
    none) ;;
    before-vg|after-vg|after-lv|before-review)
        [ "$(systemd-detect-virt --vm)" = qemu ] || skip 'Daemon restart requires a disposable QEMU guest'
        [ "${MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS:-0}" = 1 ] ||
            skip 'Set MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS=1 in the disposable QEMU guest'
        ;;
    *) fail "Unknown restart stage: $restart_stage" ;;
esac
start_lvm_fixture "$@"
raid1_types=$(lvm segtypes)
init_lvm_fixture "$1"
begin_scenario 'Missing-PV assessment and reconnection (MissingPhysicalVolumes, Structure)'
pv_count=3
if [ "$restart_stage" = before-vg ]; then restart_lvm_fixture_daemon; fi
make_fixture
if [ "$restart_stage" = after-vg ]; then restart_lvm_fixture_daemon; fi
p1=$(loop_for_image 1)
p2=$(loop_for_image 2)
p3=$(loop_for_image 3)
missing_uuid=$(pvs --noheadings -o pv_uuid "$p2" | tr -d '[:space:]')
test -n "$missing_uuid"
lvcreate --yes -L 64M -n keeper "$vg" "$p1"
lvcreate --yes -L 64M -n linear "$vg" "$p2"
write_marker "/dev/$vg/keeper"
write_marker "/dev/$vg/linear"
keeper_uuid=$(lvs --noheadings -o lv_uuid "$vg/keeper" | tr -d '[:space:]')
if [ "$restart_stage" = after-lv ]; then
    wait_lvm_activation true keeper
    previous_daemon=$(lvm_owner)
    majoris observe-restart keeper "$keeper_uuid"
    test "$(lvm_owner)" != "$previous_daemon"
    wait_lvm_activation true keeper
    verify_marker "/dev/$vg/keeper"
fi
vgchange -an "$vg"
wait_lvm_activation false keeper linear
if [ "$restart_stage" = before-review ]; then
    restart_lvm_fixture_daemon
    majoris enable-module
    wait_lvm_activation false keeper linear
    lvcreate --yes --activate n -L 16M -n substitute "$vg" "$p1"
    wait_lvm_activation false substitute
    previous_lv=$(lvs --noheadings -o lv_uuid "$vg/substitute" | tr -d '[:space:]')
    lvremove --yes "$vg/substitute"
    wait_lvm_absent substitute
    majoris stale-lv "$previous_lv"
    lvcreate --yes --activate n -L 16M -n substitute "$vg" "$p1"
    replacement_lv=$(lvs --noheadings -o lv_uuid "$vg/substitute" | tr -d '[:space:]')
    [ -n "$replacement_lv" ] && [ "$replacement_lv" != "$previous_lv" ]
    wait_lvm_activation false substitute
    majoris stale-lv "$previous_lv"
    wait_lvm_activation false substitute
    lvremove --yes "$vg/substitute"
fi
test "$(lvs --noheadings -o lv_uuid "$vg/keeper" | tr -d '[:space:]')" = "$keeper_uuid"
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
wait_lvm_absent linear
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
wait_lvm_activation true keeper
test "$(lvs --noheadings -o lv_uuid "$current_vg/keeper" | tr -d '[:space:]')" = "$keeper_uuid"
verify_marker "/dev/$current_vg/keeper"
pass_scenario
