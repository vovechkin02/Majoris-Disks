#!/bin/sh
set -eu

if [ "${MAJORIS_DISKS_RUN_LOOP_TESTS:-0}" != 1 ]; then
  echo "SKIP: set MAJORIS_DISKS_RUN_LOOP_TESTS=1 to run disposable UDisks loop tests"
  exit 77
fi

for tool in udisksctl gdbus losetup truncate mktemp; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool is unavailable"; exit 77; }
done

fixture=$(mktemp "${TMPDIR:-/tmp}/majoris-disks-loop.XXXXXX.img")
loop=""
cleanup() {
  if [ -n "$loop" ]; then
    udisksctl loop-delete --block-device "$loop" --no-user-interaction >/dev/null 2>&1 ||
      echo "WARNING: failed to detach test loop $loop" >&2
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

call --method org.freedesktop.UDisks2.Block.Format gpt "{}" >/dev/null
created=$(call --method org.freedesktop.UDisks2.PartitionTable.CreatePartition 1048576 33554432 "" "Majoris test" "{}")
partition=$(printf '%s\n' "$created" | sed -n "s/.*'\([^']*\)'.*/\1/p")
[ -n "$partition" ] || { echo "UDisks did not return a partition object" >&2; exit 1; }
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Block.Format ext4 "{'label': <'MAJORIS_TEST'>}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Filesystem.Check "{}" >/dev/null
gdbus call --system --dest org.freedesktop.UDisks2 --object-path "$partition" \
  --method org.freedesktop.UDisks2.Partition.Delete "{}" >/dev/null

echo "Disposable UDisks loop integration completed"
