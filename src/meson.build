resources = gnome.compile_resources('majoris-disks-resources',
  '../data/com.majoris.disks.gresource.xml', source_dir: '../data')

storage_model_sources = files('device.vala', 'layout.vala', 'hierarchy.vala', 'safety.vala', 'lvm-structure.vala',
  'storage-operation.vala', 'health-monitor.vala', 'disk-benchmark.vala', 'disk-image-copy.vala', 'xz-stream.c', 'nbd-identity.c', 'btrfs-inspect.c', 'virtual-disk.vala', 'virtual-disk-attachment.vala', 'blkid.vapi', 'filesystem-resize.vala', 'kernel-storage-safety.vala', 'mount-restoration.vala', 'restoration-credential.vala')
storage_model_sources += files('btrfs-quota.vala')
luks_ui_sources = files('luks-credential-dialog.vala')
sources = storage_model_sources + luks_ui_sources + files('main.vala', 'health-preferences.vala', 'benchmark-dialog.vala', 'udisks-service.vala', 'window.vala',
  'drive-view.vala', 'filesystem-usage.vala', 'partition-map.vala', 'btrfs-device-replace-dialog.vala',
  'btrfs-profile-conversion-dialog.vala', 'btrfs-quota-dialog.vala')

executable('majoris-disks', sources, resources,
  include_directories: xz_include, dependencies: deps, install: true)

executable('majoris-disks-health-monitor', storage_model_sources +
  files('health-monitor-main.vala', 'udisks-service.vala'),
  include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep], install: true)

executable('majoris-disks-nbd-helper', ['nbd-helper.c', 'nbd-identity.c'],
  dependencies: dependency('gio-2.0'), install: true, install_dir: get_option('libexecdir'))

btrfs_config = configuration_data()
btrfs_config.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(input: 'btrfs-default-config.h.in', output: 'btrfs-default-config.h', configuration: btrfs_config)
configure_file(input: '../data/com.majoris.disks.Btrfs.policy.in', output: 'com.majoris.disks.Btrfs.policy',
  configuration: btrfs_config, install_dir: get_option('datadir') / 'polkit-1' / 'actions')
btrfs_helper_sources = files('btrfs-default-helper.c', 'btrfs-inspect.c', 'btrfs-quota.c')
btrfs_default_helper = executable('majoris-disks-btrfs-default', btrfs_helper_sources,
  dependencies: [dependency('gio-2.0'), blkid_c], install: true, install_dir: get_option('libexecdir'))
btrfs_status_helper = executable('majoris-disks-btrfs-status', btrfs_helper_sources,
  c_args: '-DMAJORIS_BTRFS_STATUS_ONLY',
  dependencies: [dependency('gio-2.0'), blkid_c], install: true, install_dir: get_option('libexecdir'))

luks_config = configuration_data()
luks_config.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(input: 'luks-header-config.h.in', output: 'luks-header-config.h', configuration: luks_config)
cryptsetup_dep = dependency('libcryptsetup', version: '>=2.6', required: false)
if cryptsetup_dep.found()
  luks_header_worker = executable('majoris-disks-luks-header', 'luks-header-worker.c',
    dependencies: [cryptsetup_dep, blkid_c, dependency('json-glib-1.0')],
    install: true, install_dir: get_option('libexecdir'))
endif

crypttab_config = configuration_data()
crypttab_config.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(input: 'crypttab-inspector-config.h.in', output: 'crypttab-inspector-config.h',
  configuration: crypttab_config)
configure_file(input: '../data/com.majoris.disks.Crypttab.policy.in', output: 'com.majoris.disks.Crypttab.policy',
  configuration: crypttab_config, install_dir: get_option('datadir') / 'polkit-1' / 'actions')
crypttab_inspector = executable('majoris-disks-crypttab-inspector', 'crypttab-inspector.c',
  dependencies: dependency('gio-2.0'), install: true, install_dir: get_option('libexecdir'))

lvm_cache_config = configuration_data()
lvm_cache_config.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(input: 'lvm-cache-inspector-config.h.in', output: 'lvm-cache-inspector-config.h', configuration: lvm_cache_config)
configure_file(input: '../data/com.majoris.disks.LvmCache.policy.in', output: 'com.majoris.disks.LvmCache.policy',
  configuration: lvm_cache_config, install_dir: get_option('datadir') / 'polkit-1' / 'actions')
executable('majoris-disks-lvm-cache-inspector', 'lvm-cache-inspector.c',
  install: true, install_dir: get_option('libexecdir'))

mount_restoration_config = configuration_data()
mount_restoration_config.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(input: 'mount-restoration-config.h.in', output: 'mount-restoration-config.h',
  configuration: mount_restoration_config)
mount_dep = dependency('mount', required: false)
if mount_dep.found()
  configure_file(input: '../data/com.majoris.disks.MountRestoration.policy.in',
    output: 'com.majoris.disks.MountRestoration.policy', configuration: mount_restoration_config,
    install_dir: get_option('datadir') / 'polkit-1' / 'actions')
  mount_restoration_helper = executable('majoris-disks-mount-restoration', 'mount-restoration-helper.c',
    dependencies: [dependency('glib-2.0'), mount_dep, blkid_c],
    install: true, install_dir: get_option('libexecdir'))
endif
