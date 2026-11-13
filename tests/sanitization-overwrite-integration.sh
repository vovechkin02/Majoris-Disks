#!/bin/sh
set -eu

if [ "${MAJORIS_DISKS_RUN_SANITIZATION_TESTS:-0}" != 1 ]; then
    echo "SKIP: set MAJORIS_DISKS_RUN_SANITIZATION_TESTS=1 in the disposable QEMU guest"
    exit 77
fi
if [ "$(hostname)" != majoris-mdraid-test ] || [ "$(systemd-detect-virt --vm)" != qemu ] || [ "$(id -u)" != 0 ]; then
    echo "SKIP: requires the disposable Majoris QEMU guest and its root fixture runner"
    exit 77
fi
"$1" fixture
exec "$1" fixture-interrupt
