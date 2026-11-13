#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
inspector=$1
status=0
output=$("$inspector" /org/freedesktop/UDisks2/block_devices/loop0 2>&1) || status=$?
[ "$status" -eq 2 ]
printf '%s\n' "$output" | grep -q '^Usage:'

# A verified disposable guest can supply its own UDisks drive object.
if [ "${MAJORIS_TEST_SANITIZATION_UNSUPPORTED_DRIVE:-}" ]; then
    report=$("$inspector" "$MAJORIS_TEST_SANITIZATION_UNSUPPORTED_DRIVE")
    [ "$(printf '%s\n' "$report" | grep -c '^eligible=false$')" -eq 5 ]
    [ "$(printf '%s\n' "$report" | grep -c '^refusal=')" -eq 5 ]
fi
