#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
start_lvm_fixture "$@"
for tool in mkfs.ext4 debugfs; do
    command -v "$tool" >/dev/null || skip "$tool is unavailable"
done
types=$(lvm segtypes)
printf '%s\n' "$types" | grep -qx '[[:space:]]*cache[[:space:]]*' || skip 'The LVM cache layout is unavailable'
init_lvm_fixture "$1"
begin_scenario 'Reject a nonempty cache candidate before LogicalVolume.CacheAttach'
pv_count=2
make_fixture
p1=$(loop_for_image 1)
p2=$(loop_for_image 2)
lvcreate --yes -L 128M -n origin "$vg" "$p1"
origin=/dev/$vg/origin
check_fixture_lv "$origin"
origin_uuid=$(lvs --noheadings -o lv_uuid "$origin")
mkfs.ext4 -q -F "$origin"
debugfs -w -R "write $fixture/expected /marker" "$origin"

verify_filesystem_marker() {
    check_fixture_lv "$origin"
    test "$(lvs --noheadings -o lv_uuid "$origin")" = "$origin_uuid"
    test "$(lvs --noheadings --units b --nosuffix -o lv_size "$origin" | tr -d '[:space:]')" = 134217728
    debugfs -R 'cat /marker' "$origin" > "$fixture/readback"
    cmp "$fixture/expected" "$fixture/readback"
}

lvcreate --yes -L 128M -n used_candidate "$vg" "$p2"
write_marker "/dev/$vg/used_candidate"
wait_lvm_activation true origin used_candidate
expect_rejection 'The cache candidate contains data.' attach origin used_candidate
verify_marker "/dev/$vg/used_candidate"
mkfs.ext4 -q -F "/dev/$vg/used_candidate"
expect_rejection 'Choose an unused, active linear logical volume' attach origin used_candidate
expect_rejection 'Choose an unused, active linear logical volume' attach origin origin
pass_scenario

# Use a separate raw origin for the writeback workload so the ext4 fixture
# remains intact and no filesystem is bypassed by direct I/O.
(
    init_lvm_fixture "$1"
    begin_scenario 'Dirty writeback blocks LogicalVolume.CacheSplit and CacheDetach'
    pv_count=2
    make_fixture
    p1=$(loop_for_image 1)
    p2=$(loop_for_image 2)
    lvcreate --yes -L 128M -n raw_origin "$vg" "$p1"
    lvcreate --yes -L 128M -n raw_candidate "$vg" "$p2"
    raw_origin=/dev/$vg/raw_origin
    wait_lvm_activation true raw_origin raw_candidate
    majoris attach raw_origin raw_candidate
    check_fixture_lv "$raw_origin"
    lvchange --cachemode writeback "$raw_origin"
    for pass in $(seq 1 20); do
        for offset in 0 3 1 7 5 2 6 4; do
            dd if="$fixture/expected" of="$raw_origin" bs=64K count=1 seek="$offset" oflag=direct conv=notrunc status=none
            dd if="$raw_origin" of=/dev/null bs=64K count=1 skip="$offset" iflag=direct status=none
        done
        observed=$(lvs --noheadings -o cache_dirty_blocks "$raw_origin")
        observed=$(printf '%s' "$observed" | tr -d '[:space:]')
        case "$observed" in ''|*[!0-9]*) fail 'LVM did not report a dirty-block count';; esac
        if [ "$observed" -gt 0 ]; then break; fi
    done
    if [ "$observed" -eq 0 ]; then
        echo 'SKIP: the writeback workload produced no observable dirty blocks'
        exit 0
    fi
    echo "Observed $observed dirty blocks"
    expect_rejection 'The cache has pending writes.' split raw_origin
    expect_rejection 'The cache has pending writes.' detach raw_origin
    verify_marker "$raw_origin"
    pass_scenario
)

begin_scenario 'Cache attachment and retained pool (LogicalVolume.CacheAttach, CacheSplit)'
candidate=/dev/$vg/used_candidate
check_fixture_lv "$candidate"
pool_uuid=$(lvs --noheadings -o lv_uuid "$candidate" | tr -d '[:space:]')
test -n "$pool_uuid"
dd if=/dev/zero of="$candidate" bs=1M count=128 conv=notrunc,fsync status=none
udevadm trigger --action=change --settle "$candidate"
majoris attach origin used_candidate
test "$(lvs --noheadings -o segtype "$origin" | tr -d '[:space:]')" = cache
majoris cache-status origin "$pool_uuid"
lvchange --cachemode writethrough "$origin"
verify_filesystem_marker
debugfs -w -R "write $fixture/expected /while_cached" "$origin"
majoris cache-status origin "$pool_uuid" writethrough clean
majoris split origin
test "$(lvs -a --noheadings -o segtype --select "vg_uuid=$uuid && lv_uuid=$pool_uuid" | tr -d '[:space:]')" = cache-pool
verify_filesystem_marker
debugfs -R 'cat /while_cached' "$origin" > "$fixture/readback"
cmp "$fixture/expected" "$fixture/readback"
pass_scenario

begin_scenario 'Cache attachment and pool removal (LogicalVolume.CacheAttach, CacheDetach)'
lvcreate --yes -L 128M -n remove_pool "$vg" "$p2"
remove_uuid=$(lvs --noheadings -o lv_uuid "$vg/remove_pool" | tr -d '[:space:]')
test -n "$remove_uuid"
wait_lvm_activation true remove_pool
majoris attach origin remove_pool
majoris cache-status origin "$remove_uuid"
lvchange --cachemode writethrough "$origin"
verify_filesystem_marker
debugfs -w -R "write $fixture/expected /before_detach" "$origin"
majoris cache-status origin "$remove_uuid" writethrough clean
majoris detach origin
test "$(lvs --noheadings -o segtype "$origin" | tr -d '[:space:]')" = linear
remaining=$(lvs -a --noheadings -o lv_uuid --select "vg_uuid=$uuid && lv_uuid=$remove_uuid")
if [ -n "$remaining" ]; then
    echo 'FAIL: the removed cache pool still exists' >&2
    exit 1
fi
verify_filesystem_marker
debugfs -R 'cat /before_detach' "$origin" > "$fixture/readback"
cmp "$fixture/expected" "$fixture/readback"
pass_scenario
