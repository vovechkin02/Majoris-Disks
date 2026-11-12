#!/bin/sh
# Shared setup for an explicitly opted-in disposable Debian 13 QEMU guest.
set -eu

mdraid_require_guest() {
    [ "${MAJORIS_DISKS_RUN_MDRAID_TESTS:-}" = 1 ] || exit 77
    [ "$(id -u)" = 0 ] && [ "$(hostname)" = majoris-mdraid-test ] || exit 77
    case "$(systemd-detect-virt --vm)" in qemu|kvm) ;; *) exit 77 ;; esac
    . /etc/os-release
    [ "$ID:$VERSION_ID" = debian:13 ] || exit 77
    for tool in mdadm losetup udevadm busctl sha256sum findmnt stat realpath; do
        command -v "$tool" >/dev/null || exit 77
    done
    busctl --system status org.freedesktop.UDisks2 >/dev/null 2>&1 || exit 77
    modprobe loop
}

mdraid_uuid() {
    mdadm --detail --export "$1" | sed -n 's/^MD_UUID=//p'
}

mdraid_require_writable() {
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    udevadm settle
    state=$(cat "$kernel/array_state")
    printf 'Fixture array %s state before writes: %s\n' "$md" "$state"
    case "$state" in
        readonly|read-auto) mdadm --readwrite "$md" ;;
    esac
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    [ "$(cat "/sys/class/block/${md##*/}/ro")" = 0 ]
    case "$(cat "$kernel/array_state")" in
        active|active-idle|clean|write-pending) ;;
        *) echo 'The fixture array did not become writable' >&2; return 1 ;;
    esac
}

mdraid_owned_loop() {
    [ "$(losetup -n -O BACK-FILE "$1")" = "$2" ] || return 1
    [ -f "$2" ] && [ ! -L "$2" ] && [ "$(realpath "$2")" = "$2" ] || return 1
    if [ -f "$fixture/identities" ]; then
        recorded=$(awk -v loop="$1" '$1 == loop { print $2 " " $3 }' "$fixture/identities")
        [ "$recorded" = "$(cat "/sys/class/block/${1##*/}/diskseq") $(stat -c '%d:%i:%s' "$2")" ] || return 1
    fi
}

mdraid_record_loop() {
    printf '%s %s %s\n' "$1" "$(cat "/sys/class/block/${1##*/}/diskseq")" \
        "$(stat -c '%d:%i:%s' "$2")" >> "$fixture/identities"
}

mdraid_cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    for child in ${initiator:-} ${observer:-}; do
        kill "$child" 2>/dev/null
        wait "$child" 2>/dev/null
    done
    # Validate the entire set before making even the first cleanup mutation.
    while read -r loop image; do
        if ! mdraid_owned_loop "$loop" "$image" || findmnt -rn -S "$loop" | grep -q .; then
            printf 'Cleanup refused; retained evidence: %s (%s)\n' "$loop" "$fixture" >&2
            exit 1
        fi
        for partition in "/sys/class/block/${loop##*/}/"*/partition; do
            if [ -e "$partition" ]; then
                printf 'Partitioned fixture requires inspection: %s (%s)\n' "$loop" "$fixture" >&2
                exit 1
            fi
        done
    done < "$fixture/loops"
    if [ -z "$md" ] && [ -n "$name" ] && [ -b "/dev/md/$name" ]; then
        md=$(readlink -f "/dev/md/$name")
    fi
    if [ -n "$md" ]; then
        owns=1
        if [ -b "$md" ]; then
            if findmnt -rn -S "$md" | grep -q .; then
                printf 'Mounted fixture requires inspection: %s\n' "$fixture" >&2
                exit 1
            fi
            [ -n "$array_uuid" ] && [ "$(mdraid_uuid "$md")" = "$array_uuid" ] || owns=0
            for slave in "/sys/class/block/${md##*/}/slaves/"*; do
                [ -e "$slave" ] || continue
                loop="/dev/${slave##*/}"
                image=$(awk -v loop="$loop" '$1 == loop { print $2 }' "$fixture/loops")
                [ -n "$image" ] && mdraid_owned_loop "$loop" "$image" || owns=0
            done
            if [ "$owns" = 0 ] || ! mdadm --stop "$md"; then
                printf 'Array cleanup requires inspection: %s (%s)\n' "$md" "$fixture" >&2
                exit 1
            fi
        elif [ -e "$md" ]; then
            printf 'Array identity changed: %s (%s)\n' "$md" "$fixture" >&2
            exit 1
        fi
    fi
    while read -r loop image; do
        if ! mdraid_owned_loop "$loop" "$image" ||
            [ -n "$(ls -A "/sys/class/block/${loop##*/}/holders")" ] || ! losetup -d "$loop"; then
            printf 'Loop cleanup requires inspection: %s (%s)\n' "$loop" "$image" >&2
            exit 1
        fi
    done < "$fixture/loops"
    if [ -n "$rule" ]; then
        rm -- "$rule"
        udevadm control --reload
    fi
    rm -r -- "$fixture"
    exit "$result"
}

mdraid_setup() {
    level=$1
    count=$2
    extra=$3
    case "$level" in
        4|5|6) modprobe raid456 ;;
        *) modprobe "raid$level" ;;
    esac
    fixture=$(mktemp -d "${MDRAID_FIXTURE_PARENT:-/tmp}/majoris-mdraid.XXXXXXXX")
    md=
    name="majoris-${fixture##*.}"
    array_uuid=$(tr -d '-' < /proc/sys/kernel/random/uuid | sed 's/^\(........\)\(........\)\(........\)\(........\)$/\1:\2:\3:\4/')
    rule="/run/udev/rules.d/99-majoris-mdraid-${fixture##*.}.rules"
    touch "$fixture/loops"
    touch "$fixture/identities"
    trap mdraid_cleanup EXIT
    trap 'exit 1' HUP INT TERM
    mkdir -p /run/udev/rules.d
    # Raw loop devices are otherwise classified as system storage by UDisks.
    printf '%s\n' \
        "SUBSYSTEM==\"block\", KERNEL==\"loop*\", ATTR{loop/backing_file}==\"$fixture/*.img\", ENV{UDISKS_SYSTEM}=\"0\"" \
        "SUBSYSTEM==\"block\", KERNEL==\"md*\", ENV{MD_UUID}==\"$array_uuid\", ENV{UDISKS_SYSTEM}=\"0\"" > "$rule"
    udevadm control --reload
    i=0
    set --
    while [ "$i" -lt "$((count + extra))" ]; do
        image="$fixture/member-$i.img"
        truncate -s 80M "$image"
        loop=$(losetup --find --show "$image")
        printf '%s %s\n' "$loop" "$image" >> "$fixture/loops"
        mdraid_record_loop "$loop" "$image"
        if [ "$i" -lt "$count" ]; then set -- "$@" "$loop"; fi
        i=$((i + 1))
    done
    if [ -n "${MDRAID_LAYOUT:-}" ]; then set -- "--layout=$MDRAID_LAYOUT" "$@"; fi
    mdadm --create "/dev/md/$name" --name="$name" --uuid="$array_uuid" --metadata=1.2 --level="$level" \
        --raid-devices="$count" --bitmap=none --run "$@"
    md=$(readlink -f "/dev/md/$name")
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    kernel="/sys/class/block/${md##*/}/md"
    mdadm --wait "$md" || [ "$(cat "$kernel/sync_action")" = idle ]
    udevadm settle
    [ "$(cat "$kernel/degraded")" = 0 ]
    dd if=/dev/urandom of="$md" bs=1M count=4 conv=fsync status=none
    checksum=$(mdraid_checksum)
    for delay in 1 2 3 4 5; do
        [ "$(cat "$kernel/array_state")" = clean ] && break
        sleep 1
    done
    [ "$(cat "$kernel/array_state")" = clean ]
}

mdraid_loop() {
    awk -v row="$(( $1 + 1 ))" 'NR == row { print $1 }' "$fixture/loops"
}

mdraid_checksum() {
    dd if="$md" bs=1M count=4 status=none | sha256sum
}

mdraid_detach_member() {
    device=$1
    image=$(awk -v loop="$device" '$1 == loop { print $2 }' "$fixture/loops")
    [ -n "$image" ] && mdraid_owned_loop "$device" "$image"
    losetup -d "$device"
    udevadm settle
    [ -z "$(losetup -n -O BACK-FILE "$device" 2>/dev/null || true)" ]
    udevadm trigger --action=change "/sys/class/block/${device##*/}"
    udevadm settle
    awk -v loop="$device" '$1 != loop' "$fixture/loops" > "$fixture/remaining"
    mv "$fixture/remaining" "$fixture/loops"
    awk -v loop="$device" '$1 != loop' "$fixture/identities" > "$fixture/remaining"
    mv "$fixture/remaining" "$fixture/identities"
}

mdraid_refresh_loops() {
    while read -r loop image; do
        mdraid_owned_loop "$loop" "$image"
        udevadm trigger --action=change "/sys/class/block/${loop##*/}"
    done < "$fixture/loops"
    udevadm settle
}

mdraid_refresh() {
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    mdraid_refresh_loops
    udevadm trigger --action=change "/sys/class/block/${md##*/}"
    udevadm settle
}

mdraid_call() {
    operation=$1
    target=$2
    expected=$3
    mdraid_refresh
    "$service" "$operation" "$fixture" "$array_uuid" "$md" "$target" "$expected"
}

mdraid_transition() {
    operation=$1
    target=$2
    slot=$3
    [ "$(mdraid_uuid "$md")" = "$array_uuid" ]
    image=$(awk -v loop="$target" '$1 == loop { print $2 }' "$fixture/loops")
    [ -n "$image" ] && mdraid_owned_loop "$target" "$image"
    metadata=$(mdadm --examine --export "$target")
    [ "$(printf '%s\n' "$metadata" | sed -n 's/^MD_UUID=//p')" = "$array_uuid" ]
    member_uuid=$(printf '%s\n' "$metadata" | sed -n 's/^MD_DEV_UUID=//p')
    events=$(printf '%s\n' "$metadata" | sed -n 's/^MD_EVENTS=//p')
    [ -n "$member_uuid" ] && [ -n "$events" ]
    set --
    if [ "$operation" = re-add-member ]; then
        reviewed=$(mdraid_call review-readd "$target" 1) || return
        token=$(printf '%s\n' "$reviewed" | awk '/^re-add review / { print $4 }')
        [ "${#token}" = 64 ] || return 1
        set -- "$token"
    fi
    "$helper" "$operation" "$(cat "/sys/class/block/${md##*/}/dev")" \
        "$(cat "/sys/class/block/${md##*/}/diskseq")" \
        "$(cat "/sys/class/block/${target##*/}/dev")" "$(cat "/sys/class/block/${target##*/}/diskseq")" \
        "$array_uuid" "$member_uuid" "$slot" "$events" "$@"
}
