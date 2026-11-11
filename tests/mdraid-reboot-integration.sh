#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Explicit phases; never reboot the host and never source a persisted manifest.
set -eu
. "$(dirname "$0")/mdraid-fixture.sh"
mdraid_require_guest
service=$(realpath "$1")
phase=$2
if [ "$phase" = meson ]; then
    [ -n "${MAJORIS_MDRAID_REBOOT_MANIFEST:-}" ] || { echo 'SKIP: prepare and reboot the dedicated guest first'; exit 77; }
    phase=verify
    set -- "$1" verify "$MAJORIS_MDRAID_REBOOT_MANIFEST"
fi
umask 077
if [ "$phase" = prepare ]; then
    MDRAID_FIXTURE_PARENT=/var/tmp
    mdraid_setup 1 2 1
    printf '%s\n' "$fixture" > "$fixture/location"
    cat /etc/machine-id > "$fixture/machine-id"
    cat /proc/sys/kernel/random/boot_id > "$fixture/boot-id"
    printf '%s\n' "$array_uuid" > "$fixture/uuid"
    printf '%s\n' "$checksum" > "$fixture/checksum"
    printf '%s\n' "$name" > "$fixture/name"
    old=$(mdraid_loop 0)
    survivor=$(mdraid_loop 1)
    replacement=$(mdraid_loop 2)
    mdadm --manage "$md" --fail "$old" --remove "$old"
    printf '64\n' > "$kernel/sync_speed_min"
    printf '64\n' > "$kernel/sync_speed_max"
    mdraid_refresh
    "$service" replace "$fixture" "$array_uuid" "$md" "$replacement" 1 > "$fixture/initiator.log" 2>&1 &
    initiator=$!
    for attempt in $(seq 1 150); do
        [ "$(cat "$kernel/sync_action")" = recover ] && break
        kill -0 "$initiator" || { cat "$fixture/initiator.log"; exit 1; }
        sleep 0.2
    done
    [ "$(cat "$kernel/sync_action")" = recover ]
    [ "$(cat "$kernel/dev-${replacement##*/}/slot")" = 0 ]
    : > "$fixture/members"
    while read -r loop image; do
        mdraid_owned_loop "$loop" "$image"
        metadata=$(mdadm --examine --export "$loop")
        member=$(printf '%s\n' "$metadata" | sed -n 's/^MD_DEV_UUID=//p')
        [ -n "$member" ]
        printf '%s %s %s\n' "${image##*/}" "$(stat -c '%d:%i:%s' "$image")" "$member" >> "$fixture/members"
    done < "$fixture/loops"
    cat "$kernel/sync_action" "$kernel/sync_completed" > "$fixture/pre-reboot-state"
    kill "$initiator"
    wait "$initiator" || true
    initiator=
    printf 'prepared\n' > "$fixture/phase"
    sync
    trap - EXIT HUP INT TERM
    printf 'PREPARED (reboot not yet tested): %s\n' "$fixture"
    exit 0
fi
fixture=${3:?Supply the exact directory printed by prepare}
case "$fixture" in /var/tmp/majoris-mdraid.????????) ;; *) exit 1 ;; esac
[ "$(realpath "$fixture")" = "$fixture" ]
[ "$(stat -c '%u:%a' "$fixture")" = 0:700 ]
for record in machine-id boot-id uuid checksum name members phase pre-reboot-state; do
    [ -f "$fixture/$record" ] && [ ! -L "$fixture/$record" ]
    [ "$(stat -c '%u:%a' "$fixture/$record")" = 0:600 ]
done
cmp -s "$fixture/machine-id" /etc/machine-id
array_uuid=$(cat "$fixture/uuid")
name=$(cat "$fixture/name")
checksum=$(cat "$fixture/checksum")
rule="/run/udev/rules.d/99-majoris-mdraid-${fixture##*.}.rules"
md=
# Validate every backing inode and native metadata before attaching or cleaning anything.
while read -r image identity member; do
    case "$image" in member-[012].img) ;; *) exit 1 ;; esac
    [ -f "$fixture/$image" ] && [ ! -L "$fixture/$image" ]
    [ "$(stat -c '%d:%i:%s' "$fixture/$image")" = "$identity" ]
    metadata=$(mdadm --examine --export "$fixture/$image")
    [ "$(printf '%s\n' "$metadata" | sed -n 's/^MD_UUID=//p')" = "$array_uuid" ]
    [ "$(printf '%s\n' "$metadata" | sed -n 's/^MD_DEV_UUID=//p')" = "$member" ]
done < "$fixture/members"
[ "$(wc -l < "$fixture/members")" = 3 ]
case "$phase" in
    reboot)
        [ "$(cat "$fixture/phase")" = prepared ]
        [ "$(cat "$fixture/boot-id")" = "$(cat /proc/sys/kernel/random/boot_id)" ]
        # The environment and machine-id checks above apply to the guest only.
        active=
        for candidate in /sys/class/block/md*/md/uuid; do
            [ -r "$candidate" ] || continue
            [ "$(tr -d '-' < "$candidate")" = "$(printf '%s' "$array_uuid" | tr -d ':')" ] || continue
            [ -z "$active" ]
            active=${candidate%/uuid}
        done
        [ -n "$active" ] && [ "$(cat "$active/sync_action")" = recover ]
        # Bypass logind's SSH-session authorization; the root/guest/machine-ID
        # checks above still apply, and PID 1 performs the guest shutdown.
        systemctl reboot --force
        exit 0 ;;
    verify|cleanup) ;;
    *) exit 2 ;;
esac
if [ "$phase" = verify ]; then
    if [ "$(cat "$fixture/boot-id")" = "$(cat /proc/sys/kernel/random/boot_id)" ]; then
        echo 'FAIL: guest has not rebooted since prepare' >&2
        exit 1
    fi
    grep -qx recover "$fixture/pre-reboot-state"
fi
# Recreate ephemeral loop associations by backing identity, never by saved /dev names.
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
for candidate in /sys/class/block/md*/md/uuid; do
    [ -r "$candidate" ] || continue
    [ "$(tr -d '-' < "$candidate")" = "$(printf '%s' "$array_uuid" | tr -d ':')" ] || continue
    [ -z "$md" ] # Ambiguous UUIDs require inspection.
    disk=${candidate%/md/uuid}
    md="/dev/${disk##*/}"
done
if [ "$phase" = cleanup ]; then
    # Explicit cleanup invocation is separate from successful verification.
    [ -e "$rule" ] || rule=
    mdraid_cleanup
fi
printf '%s\n' \
    "SUBSYSTEM==\"block\", KERNEL==\"loop*\", ATTR{loop/backing_file}==\"$fixture/*.img\", ENV{UDISKS_SYSTEM}=\"0\"" \
    "SUBSYSTEM==\"block\", KERNEL==\"md*\", ENV{MD_UUID}==\"$array_uuid\", ENV{UDISKS_SYSTEM}=\"0\"" > "$rule"
udevadm control --reload
survivor=$(awk '$2 ~ /member-1.img$/ { print $1 }' "$fixture/loops")
replacement=$(awk '$2 ~ /member-2.img$/ { print $1 }' "$fixture/loops")
if [ -z "$md" ]; then
    # Normal assembly of the two recorded current members; no force or retry.
    mdadm --assemble --run "/dev/md/$name" "$survivor" "$replacement"
    md=$(readlink -f "/dev/md/$name")
fi
[ "$(mdraid_uuid "$md")" = "$array_uuid" ]
kernel="/sys/class/block/${md##*/}/md"
for slave in "/sys/class/block/${md##*/}/slaves/"*; do
    loop="/dev/${slave##*/}"
    image=$(awk -v loop="$loop" '$1 == loop { print $2 }' "$fixture/loops")
    [ -n "$image" ] && mdraid_owned_loop "$loop" "$image"
done
if [ "$(cat "$kernel/array_state")" = read-auto ]; then
    # A safe RAID1 assembly may wait read-only for its first write. Resume only
    # after validating every owned backing member above; this is not force assembly.
    mdadm --readwrite "$md"
fi
printf '200000\n' > "$kernel/sync_speed_max"
mdraid_refresh
degraded=$(cat "$kernel/degraded")
"$service" observe-terminal "$fixture" "$array_uuid" "$md" - "$degraded"
[ "$(cat "$kernel/degraded")" = 0 ]
[ "$(cat "$kernel/sync_action")" = idle ]
for pair in "$survivor:1" "$replacement:0"; do
    loop=${pair%:*}; slot=${pair##*:}
    [ "$(cat "$kernel/dev-${loop##*/}/slot")" = "$slot" ]
    grep -qw in_sync "$kernel/dev-${loop##*/}/state"
done
[ "$(mdraid_checksum)" = "$checksum" ]
printf 'verified\n' > "$fixture/phase"
printf 'PASSED: reboot, UUID, member identities, slots, synchronization and checksum; retained %s for explicit cleanup\n' "$fixture"
