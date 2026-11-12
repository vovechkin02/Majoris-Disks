#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/lvm-fixture.sh"

# All LVM and kernel commands resolve in this isolated stub directory.
scratch=$(mktemp -d)
trap 'rm -f -- "$scratch"/bin/* "$scratch"/fixture/*; rmdir "$scratch/fixture" "$scratch/bin" "$scratch"' EXIT
mkdir "$scratch/fixture"
mkdir "$scratch/bin"
for tool in losetup lvm pvcreate pvremove pvscan pvs vgcreate vgs vgchange vgremove \
    lvcreate lvchange lvs lvremove udevadm busctl dmsetup dpkg-query python3 cmp dd truncate mktemp stat sha256sum
do
    cat > "$scratch/bin/$tool" <<'EOF'
#!/bin/sh
case "${0##*/}" in
    busctl)
        case "$*" in
            '--system call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetNameOwner s org.freedesktop.UDisks2')
                [ "${NO_DAEMON:-0}" = 0 ] && printf 's ":1.9"\n' ;;
            '--system --timeout=5s introspect :1.9 /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager.LVM2')
                # An empty table still exits successfully on Debian 13.
                printf 'NAME TYPE SIGNATURE RESULT/VALUE FLAGS\n'
                if [ "${MODULE_INACTIVE:-0}" = 0 ] || [ -f "$STUB_DIR/module-active" ]; then
                    printf '.VolumeGroupCreate method saoa{sv} o -\n'
                fi ;;
            '--system --timeout=30s call :1.9 /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager EnableModule sb lvm2 true')
                [ "${ACTIVATION_FAILS:-0}" = 0 ] && : > "$STUB_DIR/module-active" ;;
            *) exit 1 ;;
        esac
        ;;
    dpkg-query) [ "${NO_PACKAGE:-0}" = 0 ] && printf installed ;;
    dmsetup) [ "$*" = version ] ;;
    losetup) [ "$*" = --find ] && [ "${NO_LOOP:-0}" = 0 ] ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$scratch/bin/$tool"
done
for tool in awk sed seq sleep; do ln -s "$(command -v "$tool")" "$scratch/bin/$tool"; done

probe() (
    rm -f -- "$scratch/bin/module-active"
    export STUB_DIR="$scratch/bin"
    PATH=$scratch/bin
    require_lvm_tools
)
expect_skip() {
    status=0
    output=$("$@" 2>&1) || status=$?
    test "$status" = 77 || fail "Expected a prerequisite skip, got $status: $output"
    case "$output" in *"$reason"*) ;; *) fail "Unexpected skip: $output" ;; esac
}

probe
MODULE_INACTIVE=1 probe
test -f "$scratch/bin/module-active"
status=0
output=$(MODULE_INACTIVE=1 ACTIVATION_FAILS=1 probe 2>&1) || status=$?
test "$status" = 1
case "$output" in *'module activation failed'*) ;; *) fail "Unexpected activation diagnostic: $output" ;; esac
reason='udisks2-lvm2 package is missing'
NO_PACKAGE=1 expect_skip probe
reason='UDisks daemon is unavailable'
NO_DAEMON=1 expect_skip probe
reason='No loop devices are available'
NO_LOOP=1 expect_skip probe
rm -- "$scratch/bin/pvcreate"
reason='pvcreate is unavailable'
expect_skip probe
reason='Set MAJORIS_DISKS_RUN_LVM_TESTS=1'
MAJORIS_DISKS_RUN_LVM_TESTS=0 expect_skip start_lvm_fixture /nonexistent

# A transport or driver failure is never evidence of an eligibility rejection.
udevadm() { return 0; }
driver=/nonexistent
fixture=$scratch
vg=majoris_lvm_mock
uuid=mock
status=0
(expect_rejection 'incomplete allocation' cleanup mock) || status=$?
test "$status" = 1

# Model cleanup with no block devices. Check that no destructive command
# runs when a saved identity is uncertain.
fixture=$scratch/fixture
vg=majoris_lvm_mock
uuid=original-vg
fixture_vg_created=1
touch "$fixture/pv-1.img"
stat -c '%d:%i:%s' "$fixture/pv-1.img" > "$fixture/pv-1.identity"
printf 'original-pv\n' > "$fixture/pv-1.uuid"

loop_for_image() { printf '%s\n' "${attached_device:-/dev/test-loop}"; }
check_pv() { check_image "$1" && [ "$2" = /dev/test-loop ]; }
vgs() {
    case "$*" in
        '--noheadings -o vg_name --select vg_uuid=original-vg') printf '%s\n' "${observed_vg:-$vg}" ;;
        '--noheadings -o vg_missing_pv_count --select vg_uuid=original-vg') printf '0\n' ;;
    esac
}
pvs() {
    case "$*" in
        '--noheadings -o pv_uuid /dev/test-loop') printf '%s\n' "${observed_pv:-original-pv}" ;;
        '--noheadings -o pv_name --select vg_uuid=original-vg') printf '%s\n' "${member:-/dev/test-loop}" ;;
        *) return 1 ;;
    esac
}
vgchange() { touch "$fixture/unsafe-mutation"; return 1; }
vgremove() { touch "$fixture/unsafe-mutation"; return 1; }
losetup() { touch "$fixture/unsafe-mutation"; return 1; }

refuse_cleanup() {
    if clean_lvm_fixture; then fail 'Cleanup accepted uncertain identity'; fi
    test -f "$fixture/pv-1.img"
    test ! -e "$fixture/unsafe-mutation"
}

observed_pv=replaced-pv refuse_cleanup
observed_vg=unrelated-vg refuse_cleanup
member=/dev/unrelated refuse_cleanup
attached_device=/dev/reused-loop refuse_cleanup
uuid= refuse_cleanup
fixture_vg_created=0 refuse_cleanup
mv "$fixture/pv-1.img" "$fixture/old.img"
touch "$fixture/pv-1.img"
refuse_cleanup

# Setup errors must stop before the next mutation. These functions never
# resolve the host's LVM commands or open block devices.
simulate_creation_failure() (
    set -e
    fixture=$scratch/fixture
    vg=majoris_lvm_mock
    pv_count=1
    truncate() { : > "$3"; }
    attach_pv() { printf '/dev/test-loop\n'; }
    check_pv() { check_image "$1" && [ "$2" = /dev/test-loop ]; }
    pvcreate() {
        touch "$fixture/pv-attempt"
        [ "$1" = --yes ] && [ "$2" = /dev/test-loop ]
        if [ "$failure_step" = pv ]; then return 9; fi
    }
    vgcreate() {
        touch "$fixture/vg-attempt"
        return 10
    }
    make_fixture
)

set +e
failure_step=pv simulate_creation_failure
status=$?
set -e
test "$status" = 9
test -e "$fixture/pv-attempt"
test ! -e "$fixture/vg-attempt"

set +e
failure_step=vg simulate_creation_failure
status=$?
set -e
test "$status" = 10
test -e "$fixture/vg-attempt"
