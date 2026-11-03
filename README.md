# Majoris Disks

Disks is the native GTK4 and libadwaita storage inspector for Majoris. It uses the UDisks2 system bus to discover physical drives, removable media, loop images and standalone blocks. GPT and MBR volumes appear in physical order alongside a keyboard-selectable allocation map.

## Build and test

On Debian, install `build-essential`, `meson`, `ninja-build`, `valac`, `libgtk-4-dev`, `libadwaita-1-dev`, `libglib2.0-dev`, and `udisks2`. The build requires libadwaita 1.5 or later.

```sh
meson setup build
meson compile -C build
meson test -C build --print-errorlogs
./build/src/majoris-disks
```

Run as your desktop user with UDisks2 and a session Polkit agent. Discovery reads UDisks properties without interactive authorization. Mounting, unmounting and swap activation request authorization through UDisks. Unmount capability consults the storage dependency graph for system-critical filesystems and active dependents. UDisks performs authorization and checks whether the mount is busy. Open in Files uses the desktop's configured file manager.

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

The allocation map is informational. RAID and LVM relationships depend on the interfaces exported by UDisks. Partition editing, formatting, encryption changes and disk imaging are outside this stage.
