#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
skip() { echo "SKIP: $*"; exit 77; }
[ "${MAJORIS_DISKS_RUN_POWER_LOSS_TESTS:-0}" = 1 ] || skip 'Enable only in a dedicated disposable QEMU guest'
[ "$(id -u)" = 0 ] && [ "$(systemd-detect-virt --vm)" = qemu ] || skip 'Requires root inside QEMU'
. /etc/os-release
[ "$ID:$VERSION_ID" = debian:13 ] || skip 'Requires Debian 13'

case "${1:-}" in
    prepare)
        driver=$(realpath "$2")
        test -x "$driver"
        checkpoint=$3
        case "$checkpoint" in before-rename|before-directory-sync|after-directory-sync|incomplete-output) ;; *) exit 2 ;; esac
        fixture=$(mktemp -d /var/tmp/majoris-publication.XXXXXXXX)
        mkdir "$fixture/work"
        count=8
        if [ "$checkpoint" = incomplete-output ]; then count=4; fi
        dd if=/dev/urandom of="$fixture/work/image" bs=1M count="$count" status=none
        printf '%s\n' 'existing image sentinel' > "$fixture/protected.img"
        sha256sum "$fixture/work/image" | cut -d' ' -f1 > "$fixture/sha256"
        stat -c '%i:%s' "$fixture/work/image" > "$fixture/image-identity"
        cat /proc/sys/kernel/random/boot_id > "$fixture/boot-id"
        cat /etc/machine-id > "$fixture/machine-id"
        printf '%s\n' "$checkpoint" > "$fixture/checkpoint"
        printf '%s\n' "$driver" > "$fixture/driver"
        sync -f "$fixture"
        printf 'Fixture %s\n' "$fixture"
        XDG_STATE_HOME="$fixture/state" exec "$driver" --publication-power-loss-worker "$fixture" "$checkpoint"
        ;;
    verify|cleanup)
        fixture=$2
        case "$fixture" in /var/tmp/majoris-publication.????????) ;; *) exit 2 ;; esac
        test "$(realpath -- "$fixture")" = "$fixture"
        test "$(stat -c '%u:%a' "$fixture")" = 0:700
        cmp /etc/machine-id "$fixture/machine-id"
        ! cmp -s /proc/sys/kernel/random/boot_id "$fixture/boot-id"
        checkpoint=$(cat "$fixture/checkpoint")
        temporary=$fixture/work/image
        destination=$fixture/published.img
        case "$checkpoint" in
            before-rename|incomplete-output) test ! -e "$destination"; observed=$temporary ;;
            before-directory-sync)
                if [ -e "$destination" ]; then observed=$destination; test ! -e "$temporary"
                else observed=$temporary; fi ;;
            after-directory-sync) observed=$destination; test ! -e "$temporary" ;;
            *) exit 2 ;;
        esac
        test ! -L "$observed"
        test "$(stat -c '%i:%s' "$observed")" = "$(cat "$fixture/image-identity")"
        test "$(sha256sum "$observed" | cut -d' ' -f1)" = "$(cat "$fixture/sha256")"
        test "$(cat "$fixture/protected.img")" = 'existing image sentinel'
        qemu-img info --output=json "$observed" | grep -Eq '"format":[[:space:]]*"raw"'
        driver=$(cat "$fixture/driver")
        XDG_STATE_HOME="$fixture/state" "$driver" --publication-power-loss-recover
        echo "PASS: $checkpoint preserved the original inode and checksum at $observed"
        if [ "$1" = cleanup ]; then
            set -- "$fixture"/state/majoris-disks/imaging/*.ini
            [ "$#" = 1 ] && [ -f "$1" ] && [ ! -L "$1" ]
            grep -Fxq "target=$destination" "$1"
            rm -- "$1"
            rmdir -- "$fixture/state/majoris-disks/imaging" "$fixture/state/majoris-disks" "$fixture/state"
            rm -- "$observed" "$fixture/checkpoint" "$fixture/machine-id" "$fixture/boot-id" \
                "$fixture/image-identity" "$fixture/sha256" "$fixture/driver" "$fixture/protected.img"
            rmdir -- "$fixture/work" "$fixture"
        fi
        ;;
    *) echo "Usage: $0 prepare TEST_DRIVER CHECKPOINT | verify FIXTURE | cleanup FIXTURE" >&2; exit 2 ;;
esac
