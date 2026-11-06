# Majoris Disks 0.2.0

Disks is the native GTK4 and libadwaita storage inspector for Majoris. It uses the UDisks2 system bus to discover physical drives, removable media, loop images and standalone blocks. GPT and MBR volumes appear in physical order alongside a keyboard-selectable allocation map.

## Build and test

On Debian, install `build-essential`, `meson`, `ninja-build`, `valac`, `libgtk-4-dev`, `libadwaita-1-dev`, `libglib2.0-dev`, `libblkid-dev`, `libjson-glib-dev`, `liblzma-dev`, and `udisks2`. The build requires libadwaita 1.5 or later.

```sh
meson setup build --prefix=/usr --sysconfdir=/etc
meson compile -C build
meson test -C build --print-errorlogs
./build/src/majoris-disks
```

Run as your desktop user with UDisks2 and a session Polkit agent. Discovery reads UDisks properties without interactive authorization. Mounting, unmounting and swap activation request authorization through UDisks. Unmount capability consults the storage dependency graph for system-critical filesystems and active dependents. UDisks performs authorization and checks whether the mount is busy. Open in Files uses the desktop's configured file manager.

Offline resize verification uses libblkid metadata and can request a read-only block descriptor through UDisks for protected devices. The local ext fallback uses `dumpe2fs` from `e2fsprogs`. When authoritative capacity or a known filesystem UUID cannot be verified, resize reports the unverified result.

UDisks unlock supports passphrases, read-only access, and single LUKS keyfiles. VeraCrypt keyfiles and advanced credential options require a separate authorized cryptsetup backend.

## Health, benchmarks, and disk images

The installed desktop autostart entry starts `majoris-disks-health-monitor` independently of the Disks window. It monitors cached UDisks health data without issuing SMART refresh commands that can wake drives. Preferences in the application menu control warning, critical-failure, and failed-self-test notifications.

Drive Actions offers raw backup and restoration. A raw backup of active storage may contain inconsistent data. Restoration checks the selected target, takes an exclusive UDisks descriptor, and verifies the bytes by readback before requesting a rescan. Restoration writes the image-length region and preserves bytes beyond it. For `.img.xz` images, liblzma validates the complete stream before writing. The second pass decodes directly to the target and compares its digest against preflight and target readback.

Disk benchmarks measure read throughput and access latency. The optional write benchmark uses a disposable scratch file in the folder you select. The application menu also creates sparse raw images and attaches raw images through UDisks.

For optional VHD, VHDX, and QCOW2 inspection, creation, and conversion, install Debian's `qemu-utils` and a version of `bubblewrap` supporting `--ro-bind-fd`. The sandbox needs working user namespaces. The application can attach a saved raw conversion read-only. Virtual images with external backing or data files are unsupported.

Direct VHD, VHDX and QCOW2 attachment also requires `libnbd0`, `util-linux`, the Linux NBD module with partition support, and the installed Majoris system-bus helper and Polkit policy. The sandboxed QEMU exporter runs as the desktop user. The helper handles only attachment and detachment of negotiated local sockets and checks kernel ownership before disconnecting. Read-only attachment is the default. Mount filesystems only from trusted images.

For isolated Debian test systems, `MAJORIS_DISKS_RUN_NBD_TESTS=1` enables the disposable NBD lifecycle test. Install the helper and policy before running it. The separate raw/XZ device tests still use `MAJORIS_DISKS_RUN_LOOP_TESTS=1`.

## Architecture

- `src/device.vala` defines storage entities and the persistent device list.
- `src/udisks-service.vala` refreshes D-Bus metadata, coalesces notifications and updates existing model objects.
- `src/hierarchy.vala` links physical drives, volumes, MBR containers and unlocked mappings. It derives available volume actions from model state.
- `src/layout.vala` calculates gaps from checked physical extents. Displayed gaps are derived from known partition extents. Confirmed allocation boundaries remain unknown.
- `data/ui/` contains GtkBuilder templates compiled into a GResource.
- `tests/` uses in-memory models to exercise layout, hierarchy and capabilities without accessing storage devices.

## Manual checks on Linux

1. Launch with UDisks running. Select the system disk and open Drive Information. Check the displayed identifiers against the UDisks metadata.
2. Attach a disposable removable device with partitions. Select a region in the map and verify that its volume row is selected. Select a different row and check the corresponding map highlight.
3. Mount a disposable data filesystem and check the mount path, usage and Open in Files action. Unmount it and confirm the selected drive and volume remain selected. Remove the device and verify the selection falls back safely.
4. Repeat with an unpartitioned removable filesystem, an empty optical drive, a loop device, and an encrypted volume unlocked externally. Verify the mapping appears under the encrypted volume and an MBR logical partition appears in its extended container's track.
5. In a disposable VM, disconnect and reconnect the UDisks service. Verify the status page appears and the device list repopulates. Check narrow-window navigation and map keyboard focus.

Destructive operations are serialized per dependency graph and revalidate device identity immediately before writes. Filesystem shrinking is enabled only when UDisks reports an appropriate resize mode and a filesystem-specific minimum-size probe succeeds. The application never performs a partition-only shrink around a recognized or unknown filesystem.

Advanced RAID, LVM and Btrfs relationships are displayed when exported by UDisks. Availability of individual maintenance operations depends on the installed UDisks modules and filesystem utilities.
