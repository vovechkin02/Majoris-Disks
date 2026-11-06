resources = gnome.compile_resources('majoris-disks-resources',
  '../data/com.majoris.disks.gresource.xml', source_dir: '../data')

storage_model_sources = files('device.vala', 'layout.vala', 'hierarchy.vala', 'safety.vala',
  'storage-operation.vala', 'blkid.vapi', 'filesystem-resize.vala', 'kernel-storage-safety.vala')
sources = storage_model_sources + files('main.vala', 'udisks-service.vala', 'window.vala',
  'drive-view.vala', 'filesystem-usage.vala', 'partition-map.vala')

executable('majoris-disks', sources, resources,
  dependencies: deps, install: true)
