#!/bin/sh
set -eu

for tool in mktemp truncate mkfs.ext4 blkid dumpe2fs; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool is unavailable"; exit 77; }
done

fixture=$(mktemp "${TMPDIR:-/tmp}/majoris-disks-capacity.XXXXXX.img")
cleanup() { rm -f -- "$fixture"; }
trap cleanup EXIT HUP INT TERM

truncate -s 64M "$fixture"
mkfs.ext4 -q -F "$fixture"
metadata=$(blkid --probe --output export "$fixture")

type=$(printf '%s\n' "$metadata" | sed -n 's/^TYPE=//p')
size=$(printf '%s\n' "$metadata" | sed -n 's/^FSSIZE=//p')
block_size=$(printf '%s\n' "$metadata" | sed -n 's/^FSBLOCKSIZE=//p')

[ "$type" = ext4 ] || { echo "Expected ext4 TYPE metadata" >&2; exit 1; }
[ -n "$size" ] || { echo "libblkid did not report FSSIZE" >&2; exit 1; }
[ -n "$block_size" ] || { echo "libblkid did not report FSBLOCKSIZE" >&2; exit 1; }
case "$size:$block_size" in
  *[!0-9:]*|:*|*:) echo "Invalid filesystem capacity metadata" >&2; exit 1 ;;
esac
[ "$size" -le 67108864 ] || { echo "FSSIZE exceeds the fixture" >&2; exit 1; }
[ "$size" -gt 66000000 ] || { echo "FSSIZE is unexpectedly smaller than the fixture" >&2; exit 1; }

printf 'Verified ext4 metadata: FSSIZE=%s FSBLOCKSIZE=%s\n' "$size" "$block_size"

# Check the independent ext superblock geometry and identity against libblkid.
header=$(LC_ALL=C dumpe2fs -h "$fixture" 2>/dev/null)
ext_uuid=$(printf '%s\n' "$header" | sed -n 's/^Filesystem UUID:[[:space:]]*//p')
blkid_uuid=$(printf '%s\n' "$metadata" | sed -n 's/^UUID=//p')
blocks=$(printf '%s\n' "$header" | sed -n 's/^Block count:[[:space:]]*//p')
ext_block_size=$(printf '%s\n' "$header" | sed -n 's/^Block size:[[:space:]]*//p')
[ -n "$ext_uuid" ] && [ "$ext_uuid" = "$blkid_uuid" ]
[ "$ext_block_size" -eq "$block_size" ]
[ "$((blocks * ext_block_size))" -eq "$size" ]

if [ "$#" -gt 0 ]; then
  MAJORIS_CAPACITY_FIXTURE="$fixture" MAJORIS_CAPACITY_UUID="$blkid_uuid" \
    "$1" -p /operations/capacity-descriptor-fixture
fi
