#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
skip() { echo "SKIP: $*"; exit 77; }
[ "${MAJORIS_DISKS_RUN_UDISKS_RESTART_TESTS:-0}" = 1 ] ||
    skip 'The disabled module probe requires explicit restart opt-in'
[ "$(id -u)" = 0 ] && [ "$(systemd-detect-virt --vm)" = qemu ] || skip 'Requires root in QEMU'
. /etc/os-release
[ "$ID:$VERSION_ID" = debian:13 ] || skip 'Requires Debian 13'
test -x "$1"
daemon=/usr/libexec/udisks2/udisksd
test -x "$daemon"
systemctl is-active --quiet udisks2
[ -z "$(systemctl show -p DropInPaths --value udisks2)" ] || skip 'The guest already has UDisks service overrides'
directory=/run/systemd/system/udisks2.service.d
mkdir -p "$directory"
override=$directory/90-majoris-disabled-module-test.conf
(set -C; printf '[Service]\nExecStart=\nExecStart=%s --disable-modules\n' "$daemon" > "$override")
identity=$(stat -c '%d:%i' "$override")
cleanup() {
    status=$?
    trap - EXIT
    if [ "$(stat -c '%d:%i' "$override")" != "$identity" ]; then
        echo "FAIL: override identity changed; retained $override" >&2
        exit 1
    fi
    rm -- "$override" && systemctl daemon-reload && systemctl restart udisks2 || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
systemctl daemon-reload
systemctl restart udisks2
"$1" --disabled-module
