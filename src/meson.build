resources = gnome.compile_resources('majoris-disks-resources',
  '../data/com.majoris.disks.gresource.xml',
  source_dir: '../data')

sources = files('main.vala', 'device.vala', 'layout.vala', 'hierarchy.vala', 'safety.vala',
  'udisks-service.vala', 'storage-operation.vala', 'kernel-storage-safety.vala', 'window.vala', 'drive-view.vala', 'filesystem-usage.vala', 'partition-map.vala')

executable('majoris-disks', sources, resources,
  dependencies: deps, install: true)




