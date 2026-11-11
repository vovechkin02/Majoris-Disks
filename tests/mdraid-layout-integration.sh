#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
case "$2" in
    near3) MDRAID_LAYOUT=n3; count=6; expected=259 ;;
    far2) MDRAID_LAYOUT=f2; count=4; expected=513 ;;
    offset2) MDRAID_LAYOUT=o2; count=4; expected=66049 ;;
    odd) MDRAID_LAYOUT=n2; count=5; expected=258 ;;
    *) exit 2 ;;
esac
mdraid_setup 10 "$count" 1
printf 'Observed RAID10 layout %s\n' "$(cat "$kernel/layout")"
[ "$(cat "$kernel/layout")" = "$expected" ]
missing=$(mdraid_loop 0)
mdadm --manage "$md" --fail "$missing" --remove "$missing"
mdraid_call refuse - 1
[ "$(cat "$kernel/degraded")" = 1 ]
[ "$(mdraid_checksum)" = "$checksum" ]
