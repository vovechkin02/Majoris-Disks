#!/bin/sh
# Run only in a dedicated VM. Use a private PID/mount namespace and a new loop.
set -eu
skip() { printf 'Skipped: %s\n' "$*"; exit 77; }
[ "${MAJORIS_TEST_MOUNT_RESTORATION:-}" = 1 ] || skip "set MAJORIS_TEST_MOUNT_RESTORATION=1 in an isolated Debian test environment"
[ "$(id -u)" = 0 ] || skip "requires root for disposable loop storage"
for command in unshare losetup mkfs.ext4 e2fsck findmnt mountpoint blockdev timeout tune2fs blkid lsblk; do
    command -v "$command" >/dev/null || skip "$command unavailable"
done
if [ "${2:-}" != private ]; then
    unshare --pid --fork --mount --mount-proc --propagation private true || skip "isolated namespaces unavailable"
    exec unshare --pid --fork --mount --mount-proc --propagation private sh "$0" "$1" private
fi
[ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ] || exit 2
helper=$(realpath "$1")
losetup -f >/dev/null || skip "loop devices unavailable"
umask 077
fixture=$(mktemp -d /mnt/majoris-mounts.XXXXXX)
first=$fixture/first
second=$fixture/second
bind=$fixture/bind
image=$fixture/device.img
loop=
pid=
busy=
outside=
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
    if [ -n "$busy" ]; then kill "$busy" 2>/dev/null || :; wait "$busy" 2>/dev/null || :; fi
    if [ -n "$outside" ]; then umount "$outside" 2>/dev/null || :; rmdir "$outside" 2>/dev/null || :; fi
    umount "$first/nested" 2>/dev/null || :
    umount "$bind" 2>/dev/null || :
    umount "$second" 2>/dev/null || :
    umount "$first" 2>/dev/null || :
    if [ -n "$loop" ] && [ "$(losetup -n -O BACK-FILE -- "$loop" 2>/dev/null)" = "$image" ]; then
        losetup -d "$loop"
    fi
    rm -f -- "$fixture/request" "$fixture/reply" "$fixture/foreign-ready" "$image"
    [ ! -L "$bind" ] || rm -- "$bind"
    rmdir "$first" "$second" "$bind" "$fixture/saved" "$fixture" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
mkdir "$first" "$second" "$bind"
truncate -s 64M "$image"
loop=$(losetup --find --show -- "$image")
[ "$(losetup -n -O BACK-FILE -- "$loop")" = "$image" ]
mkfs.ext4 -q "$loop"
number=$(lsblk -dn -o MAJ:MIN "$loop" | tr -d " ")
start() {
    mkfifo "$fixture/request" "$fixture/reply"
    timeout 30 "$helper" "$number" 0 <"$fixture/request" >"$fixture/reply" &
    pid=$!
    exec 3>"$fixture/request" 4<"$fixture/reply"
    read -r response <&4
    case "$response" in ready\ *) ;; *) exit 1 ;; esac
}
request() {
    printf '%s\n' "$1" >&3
    read -r response <&4
    [ "$response" = "$2" ] || { echo "Expected $2, received $response"; exit 1; }
}
end() {
    exec 3>&- 4<&-
    wait "$pid"
    pid=
    rm -- "$fixture/request" "$fixture/reply"
}
setup() {
    mount -o nodev,nosuid "$loop" "$first"
    mkdir -p "$first/projects"
    printf 'known contents\n' > "$first/projects/sample"
    case "$1" in ordinary|combined) mount -o nodev,nosuid,noexec "$loop" "$second";; esac
    case "$1" in bind|combined) mount --bind "$first/projects" "$bind";; esac
}
unmount_fixture() {
    if mountpoint -q "$bind"; then umount "$bind"; fi
    if mountpoint -q "$second"; then umount "$second"; fi
    umount "$first"
}
topology() {
    findmnt -rn -o MAJ:MIN,FSROOT,TARGET,FSTYPE,VFS-OPTIONS,FS-OPTIONS |
        awk -v fixture="$fixture/" 'index($3,fixture)==1' | sort
}
for layout in ordinary bind combined; do
    setup "$layout"
    before=$(topology)
    start
    request prepare prepared
    [ -z "$(topology)" ]
    request idle idle
    e2fsck -fn "$loop" >/dev/null
    request restore restored
    end
    [ "$(topology)" = "$before" ]
    [ "$(cat "$first/projects/sample")" = 'known contents' ]
    if mountpoint -q "$bind"; then [ "$(cat "$bind/sample")" = 'known contents' ]; fi
    unmount_fixture
done

setup combined
start
request prepare prepared
mv -- "$bind" "$fixture/saved"
ln -s "$second" "$bind"
request restore restore-failed
end
[ "$(cat "$first/projects/sample")" = 'known contents' ]
mountpoint -q "$second"
[ -L "$bind" ]
rm -- "$bind"
mv -- "$fixture/saved" "$bind"
unmount_fixture

setup combined
mount --make-shared "$bind"
status=0
timeout 10 "$helper" "$number" 0 </dev/null || status=$?
[ "$status" = 2 ]
mountpoint -q "$first"
mountpoint -q "$second"
mountpoint -q "$bind"
umount "$bind"
mount --bind "$first/projects" "$bind"
start
# The last mount is removed first. Keep the next mount busy.
(cd "$second" && exec sleep 30) &
busy=$!
# Give the child time to enter the mount.
sleep 1
request prepare prepare-failed
if mountpoint -q "$bind"; then exit 1; fi
request restore restored
end
kill "$busy"
wait "$busy" || :
busy=
[ "$(cat "$bind/sample")" = 'known contents' ]
unmount_fixture
setup ordinary
start
request prepare prepared
before_uuid=$(blkid -s UUID -o value "$loop")
tune2fs -U random "$loop" >/dev/null
request restore restore-failed
end
[ -z "$(topology)" ]
tune2fs -U "$before_uuid" "$loop" >/dev/null

setup combined
outside=$(mktemp -d /var/tmp/majoris-protected-mount.XXXXXX)
mount --bind "$first" "$outside"
status=0
timeout 10 "$helper" "$number" 0 </dev/null || status=$?
[ "$status" = 2 ]
mountpoint -q "$outside"
umount "$outside"
rmdir "$outside"
outside=
unmount_fixture

setup combined
start
request prepare prepared
mount -t tmpfs tmpfs "$bind"
request restore restore-failed
end
[ "$(findmnt -n -o FSTYPE --mountpoint "$bind")" = tmpfs ]
[ "$(cat "$first/projects/sample")" = 'known contents' ]
unmount_fixture
setup ordinary
mkdir -p "$first/nested"
mount --bind "$first/projects" "$first/nested"
mount -o remount,bind,ro,nosuid,nodev "$first/nested"
before=$(topology)
start
request prepare prepared
request idle idle
request restore restored
end
[ "$(topology)" = "$before" ]
[ "$(cat "$first/nested/sample")" = 'known contents' ]
umount "$first/nested"
unmount_fixture

setup ordinary
mount --bind "$first" "$second"
status=0
timeout 10 "$helper" "$number" 0 </dev/null || status=$?
[ "$status" = 2 ]
umount "$second"
unmount_fixture
setup ordinary
unshare --mount --propagation private sh -c 'touch "$1"; exec sleep 20' sh "$fixture/foreign-ready" &
busy=$!
for attempt in 1 2 3 4 5; do
    if [ -f "$fixture/foreign-ready" ]; then break; fi
    sleep 1
done
[ -f "$fixture/foreign-ready" ]
status=0
timeout 10 "$helper" "$number" 0 </dev/null || status=$?
[ "$status" = 2 ]
kill "$busy"
wait "$busy" || :
busy=
rm -- "$fixture/foreign-ready"
mountpoint -q "$first"
mountpoint -q "$second"
unmount_fixture
echo "Passed: ordinary mounts, bind roots, nested and combined plans, unsafe topology rejection and partial preparation recovery"
