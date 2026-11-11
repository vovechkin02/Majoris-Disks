#!/bin/sh
# Test-only companion of mdraid-service-test; never installed.
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
fixture=$1
target=$2
case "$fixture" in /tmp/majoris-mdraid.????????) ;; *) exit 1 ;; esac
[ "$(stat -c '%u:%a' "$fixture")" = 0:700 ]
image=$(awk -v target="$target" '$1 == target { print $2 }' "$fixture/loops")
[ -n "$image" ] && mdraid_owned_loop "$target" "$image"
oldseq=$(cat "/sys/class/block/${target##*/}/diskseq")
[ -z "$(ls -A "/sys/class/block/${target##*/}/holders")" ]
losetup -d "$target"
udevadm settle
[ -z "$(losetup -n -O BACK-FILE "$target" 2>/dev/null || true)" ]
awk -v target="$target" '$1 != target' "$fixture/loops" > "$fixture/remaining"
mv "$fixture/remaining" "$fixture/loops"
awk -v target="$target" '$1 != target' "$fixture/identities" > "$fixture/remaining"
mv "$fixture/remaining" "$fixture/identities"
if [ "$3" = reject-target-reuse ]; then
    image="$fixture/member-reused.img"
    truncate -s 80M "$image"
    losetup "$target" "$image"
    printf '%s %s\n' "$target" "$image" >> "$fixture/loops"
    mdraid_record_loop "$target" "$image"
    [ "$(cat "/sys/class/block/${target##*/}/diskseq")" != "$oldseq" ]
fi
udevadm trigger --action=change "/sys/class/block/${target##*/}"
udevadm settle
