#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"
for tool in mkfs.ext4 debugfs; do
    command -v "$tool" >/dev/null || skip "$tool is unavailable"
done
lvm segtypes | grep -qx '[[:space:]]*cache[[:space:]]*' || skip 'The LVM cache layout is unavailable'
pv_count=2
make_fixture
p1=$(loop_for_image 1)
p2=$(loop_for_image 2)
lvcreate --yes -L 128M -n origin "$vg" "$p1"
origin=/dev/$vg/origin
check_fixture_lv "$origin"
mkfs.ext4 -q -F "$origin"
debugfs -w -R "write $fixture/expected /marker" "$origin"

verify_filesystem_marker() {
    check_fixture_lv "$origin"
    debugfs -R 'cat /marker' "$origin" > "$fixture/readback"
    cmp "$fixture/expected" "$fixture/readback"
}

lvcreate --yes -L 128M -n used_candidate "$vg" "$p2"
write_marker "/dev/$vg/used_candidate"
expect_rejection attach origin used_candidate
verify_marker "/dev/$vg/used_candidate"
lvremove --yes "/dev/$vg/used_candidate"

lvcreate --yes -L 128M -n keep_pool "$vg" "$p2"
majoris attach origin keep_pool
test "$(lvs --noheadings -o segtype "$origin" | tr -d '[:space:]')" = cache
lvchange --cachemode writethrough "$origin"
verify_filesystem_marker
debugfs -w -R "write $fixture/expected /while_cached" "$origin"
majoris split origin
test "$(lvs --noheadings -o segtype "/dev/$vg/keep_pool" | tr -d '[:space:]')" = cache-pool
verify_filesystem_marker
debugfs -R 'cat /while_cached' "$origin" > "$fixture/readback"
cmp "$fixture/expected" "$fixture/readback"

lvcreate --yes -L 128M -n remove_pool "$vg" "$p2"
majoris attach origin remove_pool
lvchange --cachemode writethrough "$origin"
verify_filesystem_marker
debugfs -w -R "write $fixture/expected /before_detach" "$origin"
majoris detach origin
test "$(lvs --noheadings -o segtype "$origin" | tr -d '[:space:]')" = linear
if lvs "/dev/$vg/remove_pool" >/dev/null 2>&1; then
    echo 'FAIL: the removed cache pool still exists' >&2
    exit 1
fi
verify_filesystem_marker
debugfs -R 'cat /before_detach' "$origin" > "$fixture/readback"
cmp "$fixture/expected" "$fixture/readback"
