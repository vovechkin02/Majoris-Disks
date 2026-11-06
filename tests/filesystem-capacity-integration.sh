#!/bin/sh
set -eu

for tool in mktemp truncate mkfs.ext4 blkid dumpe2fs; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool is unavailable"; exit 77; }
done

mode=${2:-file}
loop=""
attached=""
fixture=$(mktemp "${TMPDIR:-/tmp}/majoris-disks-capacity.XXXXXX.img")
matches_fixture() {
  [ -n "$loop" ] && [ -b "$loop" ] &&
    [ "$(cat "/sys/class/block/${loop##*/}/loop/backing_file" 2>/dev/null)" = "$fixture" ]
}
cleanup() {
  if matches_fixture; then
    if ! udisksctl loop-delete --block-device "$loop" --no-user-interaction >/dev/null; then
      echo "Could not detach disposable fixture $loop. Retained $fixture." >&2
      return 1
    fi
  elif [ -n "$attached" ]; then
    echo "Could not verify the loop fixture for cleanup. Retained $fixture." >&2
    return 1
  fi
  rm -f -- "$fixture"
}
trap 'status=$?; cleanup || status=1; exit "$status"' EXIT
trap 'exit 1' HUP INT TERM

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

if [ "$mode" = live ]; then
  command -v udisksctl >/dev/null || { echo "SKIP: udisksctl is unavailable"; exit 77; }
  fixture=$(readlink -f "$fixture")
  if ! attached=$(LC_ALL=C udisksctl loop-setup --read-only --file "$fixture" --no-user-interaction 2>&1); then
    printf 'SKIP: could not attach read-only disposable loop fixture: %s\n' "$attached"
    attached=""
    exit 77
  fi
  loop=$(printf '%s\n' "$attached" | sed -n 's/.* as \(\/dev\/loop[0-9][0-9]*\)\.$/\1/p')
  if ! matches_fixture; then
    printf 'Could not verify disposable loop setup: %s\n' "$attached" >&2
    exit 1
  fi
  MAJORIS_CAPACITY_LOOP="$loop" MAJORIS_CAPACITY_UUID="$blkid_uuid" \
    "$1" -p /operations/capacity-udisks-fixture
elif [ "$#" -gt 0 ]; then
  MAJORIS_CAPACITY_FIXTURE="$fixture" MAJORIS_CAPACITY_UUID="$blkid_uuid" \
    "$1" -p /operations/capacity-descriptor-fixture
fi
