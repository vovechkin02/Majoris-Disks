project('majoris-disks', ['vala', 'c'], version: '0.1.0', meson_version: '>=1.0')
gnome = import('gnome')
deps = [
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>=1.5'),
  dependency('gio-2.0', version: '>=2.74'),
]
subdir('src')
subdir('tests')
install_data('data/com.majoris.disks.desktop', install_dir: get_option('datadir') / 'applications')
