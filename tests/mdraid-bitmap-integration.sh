#!/bin/sh
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$1
mdraid_setup 1 2 0
[ "$(cat "$kernel/bitmap/location")" = none ]
mdraid_call bitmap-enable - 0
[ "$(cat "$kernel/bitmap/location")" != none ]
[ "$(cat "$kernel/consistency_policy")" = bitmap ]
mdraid_call bitmap-disable - 0
[ "$(cat "$kernel/bitmap/location")" = none ]
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(mdraid_checksum)" = "$checksum" ]
