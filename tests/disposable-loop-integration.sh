#!/bin/sh
set -eu

if [ "${MAJORIS_DISKS_RUN_LOOP_TESTS:-0}" != 1 ]; then
  echo "SKIP: set MAJORIS_DISKS_RUN_LOOP_TESTS=1 to run disposable UDisks loop tests"
  exit 77
fi
[ "$(id -u)" -eq 0 ] || { echo "SKIP: root is required to verify disposable kernel geometry"; exit 77; }

for tool in udisksctl gdbus losetup truncate mktemp blockdev sfdisk sha256sum dd; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool is unavailable"; exit 77; }
done

fixture=$(mktemp "${TMPDIR:-/tmp}/majoris-disks-loop.XXXXXX.img")
loop=""
cleanup() {
  if [ -n "$loop" ]; then
    backing=$(losetup --noheadings --raw --output BACK-FILE "$loop" 2>/dev/null) || backing=""
    if [ "$backing" != "$fixture" ] ||
      ! udisksctl loop-delete --block-device "$loop" --no-user-interaction >/dev/null 2>&1; then
      echo "WARNING: could not confirm fixture detach. Retaining $fixture." >&2
      return
    fi
  fi
  rm -f -- "$fixture"
}
trap cleanup EXIT HUP INT TERM
truncate -s 128M "$fixture"

setup=$(udisksctl loop-setup --file "$fixture" --no-user-interaction)
loop=$(printf '%s\n' "$setup" | sed -n "s/.* as \([^.]\+\).*/\1/p")
[ -b "$loop" ] || { echo "Could not identify the disposable loop device" >&2; exit 1; }

expected=$(readlink -f "$fixture")
actual=$(losetup --noheadings --output BACK-FILE "$loop" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ "$(readlink -f "$actual")" = "$expected" ] || {
  echo "Refusing to touch a loop device not backed by the test fixture" >&2
  exit 1
}

name=$(basename "$loop")
object="/org/freedesktop/UDisks2/block_devices/$name"
call() {
  gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$object" "$@"
}
wait_partition() {
  path=$1
  node=${path##*/}
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if [ -b "/dev/$node" ] &&
      [ "$(dirname "$(readlink -f "/sys/class/block/$node")")" = "$(readlink -f "/sys/class/block/$name")" ] &&
      gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$path" \
        --method org.freedesktop.DBus.Properties.Get org.freedesktop.UDisks2.Partition Number >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.2
  done
  echo "UDisks did not republish fixture partition $node" >&2
  return 1
}

call --method org.freedesktop.UDisks2.Block.Format gpt "{}" >/dev/null
created=$(call --method org.freedesktop.UDisks2.PartitionTable.CreatePartition 1048576 33554432 "" "Majoris test" "{}")
partition=$(printf '%s\n' "$created" | sed -n "s/.*'\([^']*\)'.*/\1/p")
[ -n "$partition" ] || { echo "UDisks did not return a partition object" >&2; exit 1; }
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Block.Format ext4 "{'label': <'MAJORIS_TEST'>}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Filesystem.Check "{}" >/dev/null
gpt_device="/dev/${partition##*/}"
gpt_start=$(cat "/sys/class/block/${partition##*/}/start")
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Partition.Resize 50331648 "{}" >/dev/null
[ "$(blockdev --getsize64 "$gpt_device")" = 50331648 ]
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Filesystem.Resize 0 "{}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Filesystem.Resize 33554432 "{}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Partition.Resize 33554432 "{}" >/dev/null
[ "$(blockdev --getsize64 "$gpt_device")" = 33554432 ]
[ "$(cat "/sys/class/block/${partition##*/}/start")" = "$gpt_start" ]
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Filesystem.Check "{}" | grep -q true
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Partition.Delete "{}" >/dev/null

# Reinitialise the same verified disposable image as MBR and exercise its
# container hierarchy. No caller-supplied block device is ever accepted.
call --method org.freedesktop.UDisks2.Block.Format dos "{}" >/dev/null
primary_reply=$(call --method org.freedesktop.UDisks2.PartitionTable.CreatePartition \
  1048576 16777216 "0x83" "" "{'partition-type': <'primary'>}")
primary=$(printf '%s\n' "$primary_reply" | sed -n "s/.*'\([^']*\)'.*/\1/p")
[ -n "$primary" ] || { echo "UDisks did not return the MBR primary partition" >&2; exit 1; }
extended_reply=$(call --method org.freedesktop.UDisks2.PartitionTable.CreatePartition \
  25165824 83886080 "0x05" "" "{'partition-type': <'extended'>}")
extended=$(printf '%s\n' "$extended_reply" | sed -n "s/.*'\([^']*\)'.*/\1/p")
[ -n "$extended" ] || { echo "UDisks did not return the MBR extended partition" >&2; exit 1; }
logical_reply=$(call --method org.freedesktop.UDisks2.PartitionTable.CreatePartition \
  27262976 16777216 "0x83" "" "{'partition-type': <'logical'>}")
logical=$(printf '%s\n' "$logical_reply" | sed -n "s/.*'\([^']*\)'.*/\1/p")
[ -n "$logical" ] || { echo "UDisks did not return the MBR logical partition" >&2; exit 1; }
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$logical" \
  --method org.freedesktop.UDisks2.Block.Format ext4 "{'label': <'MAJORIS_MBR'>}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$logical" \
  --method org.freedesktop.UDisks2.Filesystem.SetLabel MAJORIS_EDITED "{}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$logical" \
  --method org.freedesktop.UDisks2.Filesystem.Check "{}" >/dev/null
# The Debian 13 backend refused growing the populated extended partition from
# 80 to 90 MiB. Exercise supported growth of its logical child within 80 MiB.
logical_device="/dev/${logical##*/}"
primary_device="/dev/${primary##*/}"
logical_start=$(cat "/sys/class/block/${logical##*/}/start")
primary_start=$(cat "/sys/class/block/${primary##*/}/start")
primary_hash=$(dd if="$primary_device" bs=1M count=16 status=none | sha256sum)
logical_hash=$(dd if="$logical_device" bs=1M count=16 status=none | sha256sum)
sfdisk --dump "$loop"
blockdev --getsize64 "$loop"
blockdev --getss "$loop"
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$primary" \
  --method org.freedesktop.UDisks2.Partition.Resize 20971520 "{}" >/dev/null
[ "$(blockdev --getsize64 "$primary_device")" = 20971520 ]
[ "$(cat "/sys/class/block/${primary##*/}/start")" = "$primary_start" ]
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$logical" \
  --method org.freedesktop.UDisks2.Partition.Resize 33554432 "{}" >/dev/null
[ "$(blockdev --getsize64 "$logical_device")" = 33554432 ]
[ "$(cat "/sys/class/block/${logical##*/}/start")" = "$logical_start" ]
[ "$(dd if="$primary_device" bs=1M count=16 status=none | sha256sum)" = "$primary_hash" ]
[ "$(dd if="$logical_device" bs=1M count=16 status=none | sha256sum)" = "$logical_hash" ]
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$logical" \
  --method org.freedesktop.UDisks2.Filesystem.Check "{}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$logical" \
  --method org.freedesktop.UDisks2.Partition.Delete "{}" >/dev/null
wait_partition "$extended"
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$extended" \
  --method org.freedesktop.UDisks2.Partition.Delete "{}" >/dev/null
wait_partition "$primary"
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$primary" \
  --method org.freedesktop.UDisks2.Partition.Delete "{}" >/dev/null

echo "Disposable UDisks loop integration completed"
