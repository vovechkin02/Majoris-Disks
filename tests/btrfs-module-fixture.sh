#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by disposable Btrfs service fixtures.

btrfs_module_active() {
    busctl --system --timeout=5s introspect "$btrfs_daemon" /org/freedesktop/UDisks2/Manager \
        org.freedesktop.UDisks2.Manager.BTRFS 2>/dev/null |
        awk '$1 == ".CreateVolume" && $2 == "method" { found = 1 } END { exit !found }'
}

btrfs_owner() {
    busctl --system call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus GetNameOwner s org.freedesktop.UDisks2 |
        sed -n 's/^s "\(:[^"]*\)"$/\1/p'
}

require_btrfs_module_package() {
    if [ "$(dpkg-query -W -f='${db:Status-Status}' udisks2-btrfs 2>/dev/null)" != installed ]; then
        echo 'SKIP: the Debian udisks2-btrfs package is missing'
        exit 77
    fi
}

ensure_btrfs_module() {
    btrfs_daemon=$(btrfs_owner)
    [ -n "$btrfs_daemon" ] || { echo 'FAIL: UDisks is unavailable' >&2; exit 1; }
    if btrfs_module_active; then return; fi
    echo "Activating Btrfs on UDisks $btrfs_daemon"
    busctl --system --timeout=30s call "$btrfs_daemon" /org/freedesktop/UDisks2/Manager \
        org.freedesktop.UDisks2.Manager EnableModule sb btrfs true ||
        { echo "FAIL: Btrfs activation failed on $btrfs_daemon" >&2; exit 1; }
    for module_attempt in $(seq 1 40); do
        [ "$(btrfs_owner)" = "$btrfs_daemon" ] ||
            { echo 'FAIL: UDisks owner changed during Btrfs activation' >&2; exit 1; }
        if btrfs_module_active; then return; fi
        sleep 0.25
    done
    echo 'FAIL: UDisks accepted activation but did not publish Manager.BTRFS' >&2
    exit 1
}
