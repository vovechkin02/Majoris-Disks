project('majoris-disks', ['vala', 'c'], version: '0.2.0', meson_version: '>=1.0',
  license: 'GPL-3.0-or-later')
gnome = import('gnome')
add_project_arguments('--pkg=posix', language: 'vala')
add_project_arguments('-D_GNU_SOURCE', language: 'c')
blkid_c = meson.get_compiler('c').find_library('blkid', has_headers: ['blkid/blkid.h'])
xz_dep = meson.get_compiler('c').find_library('lzma', has_headers: ['lzma.h'])
xz_include = include_directories('src')
deps = [
  xz_dep,
  blkid_c,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>=1.5'),
  dependency('gio-2.0', version: '>=2.74'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0'),
]
subdir('src')
layout_test = executable('storage-model-test', 'tests/storage-model-test.vala', 'tests/mock-open-device.c',
  storage_model_sources, include_directories: [include_directories('tests'), xz_include], dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
crypttab_inspector_test = executable('crypttab-inspector-test', 'tests/crypttab-inspector-test.c',
  dependencies: dependency('gio-2.0'))
test('crypttab-inspector', crypttab_inspector_test)
sh = find_program('sh')
test('lvm-fixture', sh, args: [meson.current_source_dir() / 'tests/lvm-fixture-test.sh'])
native_xz_test = executable('native-xz-test', 'tests/xz-stream-test.c', 'src/xz-stream.c',
  include_directories: xz_include, dependencies: [dependency('gio-2.0'), xz_dep])
test('native-xz', native_xz_test)
nbd_helper_test = executable('nbd-helper-test', 'tests/nbd-helper-test.c', 'src/nbd-identity.c',
  include_directories: xz_include, dependencies: dependency('gio-2.0'))
test('nbd-helper', nbd_helper_test)
btrfs_default_test = executable('btrfs-default-test', 'tests/btrfs-default-test.c', 'src/btrfs-inspect.c', 'src/btrfs-quota.c',
  include_directories: xz_include, dependencies: [dependency('gio-2.0'), blkid_c])
test('btrfs-default-helper', btrfs_default_test)
foreach scenario : ['clean', 'multi', 'member', 'corrected', 'uncorrectable', 'metadata', 'cancel', 'external', 'degraded', 'invalid']
  test('btrfs-scrub-' + scenario, sh,
    args: [meson.current_source_dir() / 'tests/btrfs-scrub-integration.sh', btrfs_default_helper, scenario],
    depends: btrfs_status_helper, timeout: 300, is_parallel: false)
endforeach
btrfs_scrub_service_test = executable('btrfs-scrub-service-test', 'tests/btrfs-scrub-service-test.vala',
  storage_model_sources, 'src/udisks-service.vala', include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
foreach scenario : ['service', 'interruption']
  test('btrfs-scrub-' + scenario, sh,
    args: [meson.current_source_dir() / 'tests/btrfs-scrub-integration.sh', btrfs_default_helper,
      scenario, btrfs_scrub_service_test],
    depends: btrfs_status_helper, timeout: 300, is_parallel: false)
endforeach
foreach scenario : ['traditional', 'simple']
  test('btrfs-quota-' + scenario + '-integration', sh,
    args: [meson.current_source_dir() / 'tests/btrfs-quota-integration.sh', btrfs_default_helper, scenario],
    depends: btrfs_status_helper, timeout: 300, is_parallel: false)
endforeach
btrfs_quota_service_test = executable('btrfs-quota-service-test', 'tests/btrfs-quota-service-test.vala',
  storage_model_sources, 'src/udisks-service.vala', include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
test('btrfs-quota-service-integration', sh,
  args: [meson.current_source_dir() / 'tests/btrfs-quota-integration.sh', btrfs_default_helper,
    'service', btrfs_quota_service_test],
  depends: btrfs_status_helper, timeout: 300, is_parallel: false)
test('btrfs-quota-observer-restart-integration', sh,
  args: [meson.current_source_dir() / 'tests/btrfs-quota-integration.sh', btrfs_default_helper,
    'restart', btrfs_quota_service_test],
  depends: btrfs_status_helper, timeout: 300, is_parallel: false)
test('disposable-btrfs-mount-integration', sh,
  args: [meson.current_source_dir() / 'tests/disposable-btrfs-mount-integration.sh', btrfs_default_test], depends: btrfs_default_helper,
  timeout: 120)
test('btrfs-discovery-integration', sh,
  args: [meson.current_source_dir() / 'tests/btrfs-discovery-integration.sh', btrfs_default_test],
  timeout: 120, is_parallel: false)
foreach scenario : ['healthy', 'larger', 'prefer-survivor', 'failing', 'missing', 'nonredundant', 'small', 'unsafe', 'cancel']
  test('btrfs-device-replace-' + scenario, sh,
    args: [meson.current_source_dir() / 'tests/btrfs-device-replace-integration.sh', btrfs_default_helper, scenario],
    depends: btrfs_status_helper, timeout: 240, is_parallel: false)
endforeach
btrfs_profile_test = executable('btrfs-profile-conversion-test', 'tests/btrfs-profile-conversion-test.vala',
  storage_model_sources, 'src/udisks-service.vala', include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
foreach scenario : ['data', 'metadata', 'raid1c3', 'raid1c4', 'raid10', 'dup', 'combined', 'reduce', 'workspace', 'interrupt', 'cancel', 'monitor', 'missing', 'unsafe', 'restart']
  test('btrfs-profile-conversion-' + scenario, sh,
    args: [meson.current_source_dir() / 'tests/btrfs-profile-conversion-integration.sh', btrfs_profile_test, scenario],
    depends: [btrfs_default_helper, btrfs_status_helper], timeout: 360, is_parallel: false)
endforeach
btrfs_balance_faults = shared_module('btrfs-balance-faults', 'tests/btrfs-balance-faults.c',
  dependencies: [dependency('glib-2.0'), meson.get_compiler('c').find_library('dl')])
test('btrfs-scrub-faults', sh,
  args: [meson.current_source_dir() / 'tests/btrfs-scrub-integration.sh', btrfs_default_helper,
    'faults', btrfs_balance_faults],
  depends: btrfs_status_helper, timeout: 180, is_parallel: false)
test('btrfs-quota-faults-integration', sh,
  args: [meson.current_source_dir() / 'tests/btrfs-quota-integration.sh', btrfs_default_helper,
    'faults', btrfs_balance_faults],
  depends: btrfs_status_helper, timeout: 180, is_parallel: false)
test('btrfs-profile-conversion-faults', sh,
  args: [meson.current_source_dir() / 'tests/btrfs-profile-conversion-integration.sh',
    btrfs_profile_test, 'faults', btrfs_balance_faults],
  depends: [btrfs_default_helper, btrfs_status_helper], timeout: 180, is_parallel: false)
if mount_dep.found()
  test('mount-restoration-integration', sh,
    args: [meson.current_source_dir() / 'tests/mount-restoration-integration.sh', mount_restoration_helper],
    timeout: 180)
endif
test('storage-model', layout_test)
mdraid_service_test = executable('mdraid-service-test', 'tests/mdraid-service-test.vala',
  storage_model_sources, 'src/udisks-service.vala', include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
test('mdraid-model', mdraid_service_test)
foreach scenario : ['raid1', 'raid5', 'raid6', 'raid6-double', 'raid10', 'start-raid1', 'start-raid5', 'dirty-raid5', 'restart-raid1']
  test('mdraid-recovery-' + scenario, sh,
    args: [meson.current_source_dir() / 'tests/mdraid-recovery-integration.sh', mdraid_service_test, scenario],
    timeout: 300, is_parallel: false)
endforeach
test('mdraid-bitmap-integration', sh,
  args: [meson.current_source_dir() / 'tests/mdraid-bitmap-integration.sh', mdraid_service_test],
  timeout: 300, is_parallel: false)
test('mdraid-member-integration', sh,
  args: [meson.current_source_dir() / 'tests/mdraid-member-integration.sh', mdraid_service_test, mdraid_helper],
  timeout: 300, is_parallel: false)
test('mdraid-member-readd-integration', sh,
  args: [meson.current_source_dir() / 'tests/mdraid-member-integration.sh', mdraid_service_test, mdraid_helper, 'readd'],
  timeout: 300, is_parallel: false)
test('mdraid-maintenance-integration', sh,
  args: [meson.current_source_dir() / 'tests/mdraid-maintenance-integration.sh', mdraid_service_test],
  timeout: 300, is_parallel: false)
lvm_device_test = executable('lvm-device-test', 'tests/lvm-device-test.vala', storage_model_sources,
  'src/udisks-service.vala', include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
foreach scenario : ['recovery', 'cache', 'layout']
  test('lvm-' + scenario + '-integration', sh,
    args: [meson.current_source_dir() / ('tests/lvm-' + scenario + '-integration.sh'), lvm_device_test],
    timeout: 1200, is_parallel: false)
endforeach
test('filesystem-capacity-integration', sh,
  args: [meson.current_source_dir() / 'tests/filesystem-capacity-integration.sh', layout_test])
test('filesystem-capacity-udisks', sh,
  args: [meson.current_source_dir() / 'tests/filesystem-capacity-integration.sh', layout_test, 'live'],
  timeout: 60)
xvfb = find_program('xvfb-run', required: false)
if xvfb.found()
  ui_test = executable('ui-template-test', 'tests/ui-template-test.vala',
    storage_model_sources + luks_ui_sources + mdraid_ui_sources + files('src/udisks-service.vala', 'src/window.vala',
      'src/drive-view.vala', 'src/filesystem-usage.vala', 'src/partition-map.vala', 'src/health-preferences.vala',
      'src/benchmark-dialog.vala', 'src/btrfs-device-replace-dialog.vala', 'src/btrfs-profile-conversion-dialog.vala',
      'src/btrfs-quota-dialog.vala', 'src/btrfs-scrub-dialog.vala'),
    resources, include_directories: xz_include, dependencies: deps)
  test('ui-templates', xvfb, args: ['-a', ui_test])
endif
imaging_test = executable('image-device-test', 'tests/image-device-test.vala', storage_model_sources,
  'src/udisks-service.vala', include_directories: xz_include,
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
test('disposable-imaging-integration', imaging_test, timeout: 180)
test('disposable-xz-integration', imaging_test, args: ['--xz'], timeout: 180)
test('disposable-partition-image-integration', imaging_test, args: ['--partition'], timeout: 180)
test('disposable-partition-xz-integration', imaging_test, args: ['--partition', '--xz'], timeout: 180)
test('disposable-nbd-integration', imaging_test, args: ['--nbd'], timeout: 300)
test('virtual-image-growth', imaging_test, args: ['--grow'], timeout: 120)
if cryptsetup_dep.found()
  restoration_test_args = []
  if mount_dep.found()
    restoration_test_args = ['-DMAJORIS_MOUNT_RESTORATION_HELPER="' + mount_restoration_helper.full_path() + '"']
  endif
  luks_service_test = executable('luks-header-service-test', 'tests/luks-header-service-test.vala',
    storage_model_sources, 'src/udisks-service.vala',
    include_directories: xz_include,
    c_args: ['-DLUKS_HEADER_WORKER="' + luks_header_worker.full_path() + '"',
      '-DMAJORIS_CRYPTTAB_INSPECTOR="' + crypttab_inspector.full_path() + '"'] + restoration_test_args,
    dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c, xz_dep])
  luks_worker_faults = shared_module('luks-worker-faults', 'tests/luks-worker-faults.c',
    dependencies: meson.get_compiler('c').find_library('dl'))
  test('luks-header-integration', sh,
    args: [meson.current_source_dir() / 'tests/luks-header-integration.sh', luks_header_worker, luks_service_test],
    env: ['MAJORIS_TEST_FAULT_LIBRARY=' + luks_worker_faults.full_path()],
    depends: luks_worker_faults, timeout: 300)
  test('luks-resize-integration', sh,
    args: [meson.current_source_dir() / 'tests/luks-resize-integration.sh', luks_service_test],
    timeout: 300)
  test('luks-partition-resize-integration', sh,
    args: [meson.current_source_dir() / 'tests/luks-resize-integration.sh', luks_service_test, 'partition'],
    timeout: 300)
  if mount_dep.found()
    test('luks-mapping-restoration-integration', sh,
      args: [meson.current_source_dir() / 'tests/luks-mapping-restoration-integration.sh', luks_service_test],
      depends: [crypttab_inspector, luks_header_worker, mount_restoration_helper], timeout: 300)
  endif
  test('luks-configuration-integration', sh,
    args: [meson.current_source_dir() / 'tests/luks-configuration-integration.sh', luks_service_test, crypttab_inspector],
    depends: crypttab_inspector,
    timeout: 300)
endif
test('disposable-loop-integration', sh,
  args: [meson.current_source_dir() / 'tests/disposable-loop-integration.sh'],
  timeout: 120)
install_data('data/com.majoris.disks.desktop', install_dir: get_option('datadir') / 'applications')
install_data('data/com.majoris.disks.ImageMounter.desktop',
  install_dir: get_option('datadir') / 'applications')
install_data('data/com.majoris.disks.metainfo.xml', install_dir: get_option('datadir') / 'metainfo')
install_data('data/icons/hicolor/scalable/apps/com.majoris.disks.svg',
  install_dir: get_option('datadir') / 'icons/hicolor/scalable/apps')

install_data('data/com.majoris.disks.HealthMonitor.desktop',
  install_dir: get_option('datadir') / 'applications')
install_data('data/com.majoris.disks.HealthMonitor.desktop',
  install_dir: get_option('sysconfdir') / 'xdg' / 'autostart')
install_data('data/com.majoris.disks.health.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')
gnome.post_install(glib_compile_schemas: true)

nbd_service = configuration_data()
nbd_service.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(input: 'data/com.majoris.disks.Nbd.service.in', output: 'com.majoris.disks.Nbd.service',
  configuration: nbd_service, install_dir: get_option('datadir') / 'dbus-1' / 'system-services')
install_data('data/com.majoris.disks.Nbd.conf', install_dir: get_option('datadir') / 'dbus-1' / 'system.d')
install_data('data/com.majoris.disks.Nbd.policy', install_dir: get_option('datadir') / 'polkit-1' / 'actions')
