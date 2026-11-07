resources = gnome.compile_resources('majoris-disks-resources',
  '../data/com.majoris.disks.gresource.xml', source_dir: '../data')

storage_model_sources = files('device.vala', 'layout.vala', 'hierarchy.vala', 'safety.vala',
  'storage-operation.vala', 'health-monitor.vala', 'disk-benchmark.vala', 'disk-image-copy.vala', 'xz-stream.c', 'nbd-identity.c', 'virtual-disk.vala', 'virtual-disk-attachment.vala', 'blkid.vapi', 'filesystem-resize.vala', 'kernel-storage-safety.vala')
sources = storage_model_sources + files('main.vala', 'health-preferences.vala', 'benchmark-dialog.vala', 'udisks-service.vala', 'window.vala',
  'drive-view.vala', 'filesystem-usage.vala', 'partition-map.vala')

executable('majoris-disks', sources, resources,
  include_directories: xz_include, dependencies: deps, install: true)

executable('majoris-disks-health-monitor', storage_model_sources +
  files('health-monitor-main.vala', 'udisks-service.vala'),
  include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep], install: true)

executable('majoris-disks-nbd-helper', ['nbd-helper.c', 'nbd-identity.c'],
  dependencies: dependency('gio-2.0'), install: true, install_dir: get_option('libexecdir'))
