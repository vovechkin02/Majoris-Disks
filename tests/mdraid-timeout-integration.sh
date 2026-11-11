#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
faults=$(realpath "$2")
mdraid_setup 1 2 1
missing=$(mdraid_loop 0)
target=$(mdraid_loop 2)
mdadm --manage "$md" --fail "$missing" --remove "$missing"
for mode in before after; do
    mdraid_refresh
    MAJORIS_MDRAID_DBUS_FAULT=$mode MAJORIS_MDRAID_DISPATCH_LOG="$fixture/dispatch-$mode" \
        LD_PRELOAD="$faults" "$service" expect-timeout "$fixture" "$array_uuid" "$md" "$target" 1
    [ "$(wc -l < "$fixture/dispatch-$mode")" = 1 ]
    if [ "$mode" = before ]; then
        [ ! -e "$kernel/dev-${target##*/}" ]
        [ "$(cat "$kernel/degraded")" = 1 ]
    fi
done
mdadm --wait "$md" || [ "$(cat "$kernel/sync_action")" = idle ]
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(cat "$kernel/dev-${target##*/}/slot")" = 0 ]
grep -qw in_sync "$kernel/dev-${target##*/}/state"
[ "$(mdraid_checksum)" = "$checksum" ]
