project('majoris-disks', ['vala', 'c'], version: '0.2.0', meson_version: '>=1.0',
  license: 'GPL-3.0-or-later')
gnome = import('gnome')
add_project_arguments('--pkg=posix', language: 'vala')
add_project_arguments('-D_GNU_SOURCE', language: 'c')
blkid_c = meson.get_compiler('c').find_library('blkid', has_headers: ['blkid/blkid.h'])
deps = [
  blkid_c,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>=1.5'),
  dependency('gio-2.0', version: '>=2.74'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0'),
]
subdir('src')
layout_test = executable('storage-model-test', 'tests/storage-model-test.vala', 'tests/mock-open-device.c',
  storage_model_sources, 'src/virtual-disk.vala', include_directories: include_directories('tests'), dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('json-glib-1.0'), blkid_c])
sh = find_program('sh')
test('storage-model', layout_test)
test('filesystem-capacity-integration', sh,
  args: [meson.current_source_dir() / 'tests/filesystem-capacity-integration.sh', layout_test])
test('filesystem-capacity-udisks', sh,
  args: [meson.current_source_dir() / 'tests/filesystem-capacity-integration.sh', layout_test, 'live'],
  timeout: 60)
xvfb = find_program('xvfb-run', required: false)
if xvfb.found()
  ui_test = executable('ui-template-test', 'tests/ui-template-test.vala',
    storage_model_sources + files('src/udisks-service.vala', 'src/window.vala',
      'src/drive-view.vala', 'src/filesystem-usage.vala', 'src/partition-map.vala', 'src/health-preferences.vala', 'src/benchmark-dialog.vala', 'src/virtual-disk.vala'),
    resources, dependencies: deps)
  test('ui-templates', xvfb, args: ['-a', ui_test])
endif
imaging_test = executable('image-device-test', 'tests/image-device-test.vala', storage_model_sources,
  'src/udisks-service.vala', dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0'), blkid_c])
test('disposable-imaging-integration', imaging_test, timeout: 180)
test('disposable-loop-integration', sh,
  args: [meson.current_source_dir() / 'tests/disposable-loop-integration.sh'],
  timeout: 120)
install_data('data/com.majoris.disks.desktop', install_dir: get_option('datadir') / 'applications')
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
