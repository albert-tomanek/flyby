project('flyby', ['vala', 'c'])
gnome = import('gnome')

resources = gnome.compile_resources(
   'flyby_res', 'resource.xml',
    source_dir: '.',
	export: true,
)

executable('main',
	resources,
	sources: [
		'main.vala',
	],
	dependencies: [
		dependency('glib-2.0'),
		dependency('gobject-2.0'),
		dependency('gtk4'),
	],
)
