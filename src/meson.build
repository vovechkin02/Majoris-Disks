resources = gnome.compile_resources('majoris-disks-resources',
  '../data/com.majoris.disks.gresource.xml', source_dir: '../data')

storage_model_sources = files('device.vala', 'layout.vala', 'hierarchy.vala', 'safety.vala',
  'storage-operation.vala', 'health-monitor.vala', 'disk-benchmark.vala', 'disk-image-copy.vala', 'blkid.vapi', 'filesystem-resize.vala', 'kernel-storage-safety.vala')
sources = storage_model_sources + files('main.vala', 'health-preferences.vala', 'benchmark-dialog.vala', 'virtual-disk.vala', 'udisks-service.vala', 'window.vala',
  'drive-view.vala', 'filesystem-usage.vala', 'partition-map.vala')

executable('majoris-disks', sources, resources,
  dependencies: deps, install: true)

executable('majoris-disks-health-monitor', storage_model_sources +
  files('health-monitor-main.vala', 'udisks-service.vala'),
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), blkid_c], install: true)
