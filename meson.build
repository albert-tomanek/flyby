project('flyby', ['vala', 'c'])
gnome = import('gnome')

resources = gnome.compile_resources(
   'flyby_res', 'resource.xml',
    source_dir: '.',
	export: true,
)

executable('org.neocities.albertt.flyby',
	resources,
	sources: [
		'main.vala',
		'misc.vala',
		'anaglyph.vala',
		'jps_export.vala',
	],
	dependencies: [
		dependency('glib-2.0'),
		dependency('gobject-2.0'),
		dependency('gtk4'),
		dependency('gstreamer-1.0'),
		dependency('gstreamer-app-1.0'),
		dependency('gstreamer-pbutils-1.0'),
		dependency('gdk-pixbuf-2.0'),
		dependency('libgsf-1'),
		dependency('json-glib-1.0'),
	],
	install: true
)

install_data('org.neocities.albertt.flyby.gschema.xml', install_dir : get_option('datadir') / 'glib-2.0' / 'schemas')
gnome.post_install(
	glib_compile_schemas: true
)

install_data('org.neocities.albertt.flyby.desktop', install_dir: join_paths(get_option('datadir'), 'applications'))

install_data('org.neocities.albertt.flyby.svg', install_dir: join_paths(get_option('datadir'), 'icons/hicolor/scalable/apps'))

install_data('org.neocities.albertt.flyby.appdata.xml', install_dir: join_paths(get_option('datadir'), 'appdata'))

install_data('flyby-mime.xml', install_dir: join_paths(get_option('datadir'), 'mime/packages'))
