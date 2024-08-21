# meson build
# ninja -C build
# sudo ninja install -C build

# video/x-raw, width=(int)[ 1, 32767 ], height=(int)[ 1, 32767 ], framerate=(fraction)[ 0/1, 2147483647/1 ], format=(string)RGB

project('clappersink', 'c', version: '0.7.0')

gst_req = '>= 1.20.0'
glib_req = '>= 2.74.0'
gtk4_req = '>= 4.8.0'

gtk4_dep = dependency('gtk4',
  version: gtk4_req,
  required: false,
)
gst_dep = dependency('gstreamer-1.0',
  version: gst_req,
  required: false,
)
gst_base_dep = dependency('gstreamer-base-1.0',
  version: gst_req,
  required: false,
)
gst_video_dep = dependency('gstreamer-video-1.0',
  version: gst_req,
  required: false,
)
gmodule_dep = dependency('gmodule-2.0',
  version: glib_req,
  required: false,
)

prefix = get_option('prefix')
libdir = get_option('libdir')

clapper_libdir = join_paths(prefix, libdir, 'clappersink')

subdir('clapper/src/lib/gst/plugin')
