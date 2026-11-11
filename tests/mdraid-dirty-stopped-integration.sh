#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Dedicated QEMU crash test. An abrupt guest reset preserves real dirty metadata.
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$(realpath "$1")
phase=$2
if [ "$phase" = meson ]; then
    [ -n "${MAJORIS_MDRAID_DIRTY_MANIFEST:-}" ] || { echo 'SKIP: dedicated dirty-array crash phase required'; exit 77; }
    phase=verify
    set -- "$1" verify "$MAJORIS_MDRAID_DIRTY_MANIFEST"
fi
umask 077
if [ "$phase" = prepare ]; then
    case "$3" in raid5) level=5; count=3 ;; raid6) level=6; count=4 ;; *) exit 2 ;; esac
    MDRAID_FIXTURE_PARENT=/var/tmp
    mdraid_setup "$level" "$count" 0
    cat /etc/machine-id > "$fixture/machine-id"
    cat /proc/sys/kernel/random/boot_id > "$fixture/boot-id"
    printf '%s\n' "$array_uuid" > "$fixture/uuid"
    printf '%s\n' "$name" > "$fixture/name"
    printf '0\n' > "$kernel/safe_mode_delay"
    missing=$(mdraid_loop 0)
    mdadm --manage "$md" --fail "$missing" --remove "$missing"
    mdraid_detach_member "$missing"
    dd if=/dev/urandom of="$md" bs=1M count=1 seek=8 conv=fsync status=none
    [ "$(cat "$kernel/array_state")" = active ]
    [ "$(cat "$kernel/degraded")" = 1 ]
    : > "$fixture/members"
    while read -r loop image; do
        mdraid_owned_loop "$loop" "$image"
        member=$(mdadm --examine --export "$loop" | sed -n 's/^MD_DEV_UUID=//p')
        [ -n "$member" ]
        printf '%s %s %s\n' "${image##*/}" "$(stat -c '%d:%i:%s' "$image")" "$member" >> "$fixture/members"
    done < "$fixture/loops"
    sync
    [ "$(cat "$kernel/array_state")" = active ]
    trap - EXIT HUP INT TERM
    printf 'PREPARED dirty/degraded (crash not yet executed): %s\n' "$fixture"
    exit 0
fi
fixture=${3:?Exact prepared fixture directory required}
case "$fixture" in /var/tmp/majoris-mdraid.????????) ;; *) exit 1 ;; esac
[ "$(realpath "$fixture")" = "$fixture" ]
[ "$(stat -c '%u:%a' "$fixture")" = 0:700 ]
cmp -s "$fixture/machine-id" /etc/machine-id
array_uuid=$(cat "$fixture/uuid")
name=$(cat "$fixture/name")
rule="/run/udev/rules.d/99-majoris-mdraid-${fixture##*.}.rules"
while read -r image identity member; do
    case "$image" in member-[123].img) ;; *) exit 1 ;; esac
    [ ! -L "$fixture/$image" ]
    [ "$(stat -c '%d:%i:%s' "$fixture/$image")" = "$identity" ]
    metadata=$(mdadm --examine --export "$fixture/$image")
    [ "$(printf '%s\n' "$metadata" | sed -n 's/^MD_UUID=//p')" = "$array_uuid" ]
    [ "$(printf '%s\n' "$metadata" | sed -n 's/^MD_DEV_UUID=//p')" = "$member" ]
done < "$fixture/members"
case "$phase" in
    crash)
        [ "$(cat "$fixture/boot-id")" = "$(cat /proc/sys/kernel/random/boot_id)" ]
        # Explicitly designated disposable guest only. Do not run a clean shutdown.
        printf 'b\n' > /proc/sysrq-trigger
        exit 1 ;;
    verify)
        if [ "$(cat "$fixture/boot-id")" = "$(cat /proc/sys/kernel/random/boot_id)" ]; then
            echo 'FAIL: guest has not crashed since prepare' >&2
            exit 1
        fi ;;
    cleanup) ;;
    *) exit 2 ;;
esac
early_rule="/run/udev/rules.d/00-majoris-mdraid-${fixture##*.}.rules"
if [ "$phase" = verify ]; then
    # Suppress incremental assembly only for this fixture, while leaving the
    # final UDisks-ready state enabled after mdadm's rule has been skipped.
    printf '%s\n' "SUBSYSTEM==\"block\", KERNEL==\"loop*\", ATTR{loop/backing_file}==\"$fixture/*.img\", ENV{SYSTEMD_READY}=\"0\"" > "$early_rule"
    printf '%s\n' "SUBSYSTEM==\"block\", KERNEL==\"loop*\", ATTR{loop/backing_file}==\"$fixture/*.img\", ENV{UDISKS_SYSTEM}=\"0\", ENV{SYSTEMD_READY}=\"1\"" > "$rule"
    udevadm control --reload
fi
: > "$fixture/loops.new"
: > "$fixture/identities.new"
while read -r image identity member; do
    loop=$(losetup --find --show --nooverlap "$fixture/$image")
    [ "$(losetup -n -O BACK-FILE "$loop")" = "$fixture/$image" ]
    printf '%s %s\n' "$loop" "$fixture/$image" >> "$fixture/loops.new"
    printf '%s %s %s\n' "$loop" "$(cat "/sys/class/block/${loop##*/}/diskseq")" "$identity" >> "$fixture/identities.new"
done < "$fixture/members"
mv "$fixture/loops.new" "$fixture/loops"
mv "$fixture/identities.new" "$fixture/identities"
md=
if [ "$phase" = cleanup ]; then
    # Remove only the exact rule owned by the verified fixture.
    if [ -f "$early_rule" ] && [ ! -L "$early_rule" ]; then rm -- "$early_rule"; fi
    [ -e "$rule" ] || rule=
    mdraid_cleanup
fi
mdraid_refresh_loops
# Confirm the metadata itself is dirty, rather than relabel a clean stopped test.
while read -r loop image; do
    mdadm --examine "$loop" > "$fixture/examine-${loop##*/}"
    grep -Eq 'State : active' "$fixture/examine-${loop##*/}"
done < "$fixture/loops"
sha256sum "$fixture"/member-*.img > "$fixture/before.sha256"
survivor=$(mdraid_loop 0)
"$service" refuse-start "$fixture" "$array_uuid" "$survivor" - 1
sha256sum -c "$fixture/before.sha256"
for candidate in /sys/class/block/md*/md/uuid; do
    [ -r "$candidate" ] || continue
    [ "$(tr -d '-' < "$candidate")" != "$(printf '%s' "$array_uuid" | tr -d ':')" ]
done
printf 'PASSED: stopped dirty/degraded refusal, no metadata mutation; cleanup separately: %s\n' "$fixture"
