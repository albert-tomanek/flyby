// source code uses elastic tabs

// https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/tree/main/video/gtk4
// https://packages.debian.org/sid/gstreamer1.0-gtk4

// seamless loop: https://stackoverflow.com/questions/53747278/seamless-video-loop-in-gstreamer
// backwards: https://gstreamer.freedesktop.org/documentation/additional/design/trickmodes.html?gi-language=c
// images in Gtk frames: https://stackoverflow.com/questions/70921068/drag-and-drop-with-gtk4-connecting-dragsource-and-droptarget-via-contentprovide


[CCode(lower_case_cprefix = "flyby_")]
namespace FlyBy
{
	public class App : Gtk.Application {
		public static int main(string[] args)
		{
			Gst.init(ref args);

			var app = new App();
			return app.run(args);
		}

		construct {
			this.application_id = "org.neocities.albertt.flyby";
			this.flags = ApplicationFlags.HANDLES_OPEN | ApplicationFlags.HANDLES_COMMAND_LINE;

			this.command_line.connect(this.on_command_line);
		}

		bool 	arg_version	= false;
		string?	arg_input_file	= null;
		string?	arg_export_jps	= null;
		string?	arg_export_comp	= null;
		string?	arg_comp_meth_	= null;
		AnaglyphMethod arg_comp_meth;

		public int on_command_line (ApplicationCommandLine command_line) {
			int rc = 0;
			this.hold ();	// keep the application running until we are done with this commandline

			{
                var anaglyphmethod_enum = ((EnumClass) typeof(AnaglyphMethod).class_ref());

				OptionEntry[] options = {
					{ "version",	0, 0, OptionArg.NONE,	ref arg_version,	"Display version number",	null },
					{ "export-jps",	0, 0, OptionArg.FILENAME,	ref arg_export_jps,	"Export the given input file as .JPS",	"JPS_FILE" },
					{ "export-composite",	0, 0, OptionArg.FILENAME,	ref arg_export_comp,	"Composite frames in .FLYBY file into a .JPG. Must specify method with -m.",	"JPG_FILE" },
					{ "method",	'm', 0, OptionArg.STRING,	ref arg_comp_meth_,	ALL_ANAGLYPHS_STR, "METHOD" },
					{ null }
				};

				// We have to make an extra copy of the array, since .parse assumes
				// that it can remove strings from the array without freeing them.
				string[] args = command_line.get_arguments ();
				string*[] _args = new string[args.length];
				for (int i = 0; i < args.length; i++) {
					_args[i] = args[i];
				}

				try {
					var opt_context = new OptionContext ("[FILE]");
					opt_context.set_help_enabled (true);
					opt_context.add_main_entries (options, null);
					unowned string[] tmp = _args;
					opt_context.parse (ref tmp);

					arg_input_file = tmp.length >= 2 ? tmp[1] : null;

					if (arg_input_file == null && (arg_export_jps != null || arg_export_comp != null))
					{
						stderr.printf("Error: Must provide input file\n");
						return 1;
					}
					if (arg_export_comp != null)
					{
						if (arg_comp_meth_ == null)
						{
							stderr.printf("Error: Must provide composition method with -m\n");
							return 1;
						}

						var? val = anaglyphmethod_enum.get_value_by_name(arg_comp_meth_);

						if (val != null)
							arg_comp_meth = val.value;
						else
						{
							stderr.printf("Invalid argument for -m\n");
							return 1;
						}
					}

				} catch (OptionError e) {
					command_line.print ("error: %s\n", e.message);
					command_line.print ("Run '%s --help' to see a full list of available command line options.\n", args[0]);
					return 1;
				}
			}

			/*rc = */base.command_line(command_line);

			if (rc == 0)
				this.activate();

			return rc;
		}

		protected override void activate () {
			if (arg_version)
			{
				stdout.printf("%s\n", this.version);
				this.quit();
			}
			else if (arg_export_jps != null)
			{
				this.export_jps_headless.begin(
					File.new_for_path(arg_input_file),
					File.new_for_path(arg_export_jps),
					(_, ctx) => {
						try {
							this.export_jps_headless.end(ctx);
						} catch (Error e) {
							stderr.printf("Error: %s\n", e.message);
						}
						this.quit();
					}
				);
			}
			else if (arg_export_comp != null)
			{
				this.export_comp_headless.begin(
					File.new_for_path(arg_input_file),
					File.new_for_path(arg_export_comp),
                    arg_comp_meth,
					(_, ctx) => {
						try {
							this.export_comp_headless.end(ctx);
						} catch (Error e) {
							stderr.printf("Error: %s\n", e.message);
						}
						this.quit();
					}
				);
			}
			else
			{
				var win = new FlyBy.MainWindow(this);
				this.add_window(win);
				win.close_request.connect(() => {
					win.close();
					return false;   // continue closing the window
				});
				win.show();

				if (arg_input_file != null)
					win.open.begin(File.new_for_path(arg_input_file));
			}
		}

		protected override void open (File[] files, string hint) {
			foreach (var file in files)
			{
				var win = new FlyBy.MainWindow(this);
				this.add_window(win);
				win.show();

				win.open.begin(file);
			}
		}

		private async bool export_jps_headless(File in_fb, File out_jps)
		{
			var frames = new ListStore(typeof(FlyBy.Frame));
			double fps;

			yield FlyBy.NativeFile.load(in_fb, frames, out fps);

			var stage = new Stage();
			stage.frame_l = frames.get_object(0) as Frame;
			stage.frame_r = frames.get_object(1) as Frame;

			yield stage.export_stereo(out_jps, 90);
			stdout.printf("%s\n", out_jps.get_path());

			return true;
		}

		private async bool export_comp_headless(File in_fb, File out_jps, AnaglyphMethod meth)
		{
			var frames = new ListStore(typeof(FlyBy.Frame));
			double fps;

			yield FlyBy.NativeFile.load(in_fb, frames, out fps);

			var stage = new Stage();
			stage.frame_l = frames.get_object(0) as Frame;
			stage.frame_r = frames.get_object(1) as Frame;

            stage.method = meth;
			yield stage.export_composite(out_jps, 90);
			stdout.printf("%s\n", out_jps.get_path());

			return true;
		}

		// Useful stuff

		public static Gtk.FileFilter ff_images;
		public static Gtk.FileFilter ff_videos;
		public static Gtk.FileFilter ff_flyby;

        static string ALL_ANAGLYPHS_STR;

		static construct {
			ff_images = new Gtk.FileFilter() { name = "All image formats" };
			ff_images.add_mime_type("image/jpeg");
			ff_images.add_mime_type("image/png");

			ff_videos = new Gtk.FileFilter() { name = "All video formats" };
			ff_videos.add_pattern("*.mp4");

			ff_flyby = new Gtk.FileFilter() { name = "FlyBy files" };
			ff_flyby.add_pattern("*.flyby");

            //

            var anaglyphmethod_enum = ((EnumClass) typeof(AnaglyphMethod).class_ref());
            string[] anaglyphmethod_options = {};

            for (int i = anaglyphmethod_enum.minimum; i <= anaglyphmethod_enum.maximum; i++)
                anaglyphmethod_options += ((AnaglyphMethod) i).to_string();

            ALL_ANAGLYPHS_STR = "Method used for compositing frames. Possible methods: " + string.joinv(", ", anaglyphmethod_options);
		}
	}

	abstract class Frame : Object
	{
		public Gdk.Pixbuf? cache { get; set; default = null; }

		public bool hidden  { get; set; default = false; }
		public double offset_x { get; set; default = 0; }	// as percentage of width
		public double offset_y { get; set; default = 0; }	// as percentage of height
		public double roll { get; set; default = 0; }
		public double zoom { get; set; default = 1; }

		public abstract string get_display_name();
		//  public abstract string get_save_name();		// without extension

		public Gdk.Rectangle get_size()
		{
			return Gdk.Rectangle() { width = this.cache.width, height = this.cache.height };
		}
	}

	class FrameFromDisk : Frame
	{
		public File origin { get; private set; }

		public FrameFromDisk(File origin)
		{
			this.origin = origin;
			new_pixbuf_from_stream.begin(this.origin.read(), (_, res) => {
				this.cache = new_pixbuf_from_stream.end(res);
			});
		}

		private static async Gdk.Pixbuf new_pixbuf_from_stream(InputStream stream) throws Error
		{
			return yield new Gdk.Pixbuf.from_stream_async(stream);
		}

		public override string get_display_name()
		{
			return this.origin.get_basename();
		}
	}

	class FrameInMem : Frame
	{
		public string filename { get; set; }

		public override string get_display_name()
		{
			return this.filename;
		}
	}

	class Stage : Gtk.DrawingArea
	{
		// Any animation is done by the application, not inside this class

		public AnaglyphMethod method { get; set; }
		public double red_coef { get; set; }

		public bool show_l { get; set; default = true; }	// These are used for the `None, alternate` view mode
		public bool show_r { get; set; default = true; }

		public Frame frame_l { get; set; }
		unowned Frame? old_frame_l;		// for disconnecting `notify` handler.
		ulong frame_l_notify_binding;

		public Frame? frame_r { get; set; }
		unowned Frame? old_frame_r;		// for disconnecting `notify` handler.
		ulong frame_r_notify_binding;

		Gdk.Pixbuf pixbuf;

		construct {
			this.hexpand = this.vexpand = true;
			this.halign  = this.valign  = Gtk.Align.FILL;

			// Listen to parameter changes on the frames
			this.notify["frame-l"].connect(() => {
				// Stop listening to changes in the old frame.
				if (old_frame_l != null)
					old_frame_l.disconnect(frame_l_notify_binding);

				// Loading is async so we actually have to wait until the property appears
				frame_l_notify_binding = frame_l.notify.connect(() => { this.refresh_stage(); });
				// We just got a new frame_l and that means also a new frame_l.cache. Trigger a redraw.
				frame_l.notify_property("cache");

				old_frame_l = frame_l;
			});
			this.notify["frame-r"].connect(() => {
				if (old_frame_r != null)
					old_frame_r.disconnect(frame_r_notify_binding);

				if (frame_r != null)
				{
					frame_r_notify_binding = frame_r.notify.connect(() => { this.refresh_stage(); });
					frame_r.notify_property("cache");
				}

				old_frame_r = frame_r;
			});

			this.notify["method"].connect(this.refresh_stage);
			this.notify["red-coef"].connect(this.refresh_stage);
			this.notify["show-l"].connect(this.refresh_stage);
			this.notify["show-r"].connect(this.refresh_stage);

			this.set_draw_func((_, cr, w, h) => { this.draw(cr); });
			this.resize.connect(this.refresh_stage);;

			// UI stuff

			// Drag
			var drag = new Gtk.GestureDrag() {
				button = Gdk.BUTTON_PRIMARY,
			};
			this.add_controller(drag);

			double old_offset_x, old_offset_y;
			unowned Frame dragging_frame;

			drag.drag_begin.connect(() => {
				if ((this.frame_r != null && this.method != AnaglyphMethod.NONE) && ((drag.get_current_event_state() & Gdk.ModifierType.ALT_MASK) == 0))
					dragging_frame = this.frame_r;		// You generally want to be dragging the later frame as when aligning frames you tend to go from the top of the list down.
				else
					dragging_frame = this.frame_l;

				old_offset_x = dragging_frame.offset_x;
				old_offset_y = dragging_frame.offset_y;
			});
			drag.drag_update.connect((dx, dy) => {
				var letterbox = this.get_letterbox(dragging_frame.get_size(), Gdk.Rectangle() {
					width  = this.get_width(),
					height = this.get_height()
				});

				dragging_frame.offset_x = old_offset_x + (dx / letterbox.width);
				dragging_frame.offset_y = old_offset_y + (dy / letterbox.height);
			});

			// Double click (ie. reset)
			var dclick = new Gtk.GestureClick() {
				button = Gdk.BUTTON_PRIMARY,
			};
			this.add_controller(dclick);

			dclick.released.connect((nth_click, x, y) => {
				if (nth_click == 2)
				{
					this.frame_l.offset_x = 0;
					this.frame_l.offset_y = 0;
				}
			});
		}

		private void draw(Cairo.Context cr)
		{
			Gdk.cairo_set_source_pixbuf(cr, this.pixbuf, 0, 0);
			cr.paint();
		}

		private static Gdk.Rectangle get_letterbox(Gdk.Rectangle frame_sz, Gdk.Rectangle stage_sz)  // given the frame aspect ratio and the widget allocation
		{
			// Work out the size and position of the scaled image
			double src_aspect  = (double) frame_sz.width / (double) frame_sz.height;
			double dest_aspect = (double) stage_sz.width / (double) stage_sz.height;

			var letterbox = Gdk.Rectangle();

			if (src_aspect > dest_aspect) {
				letterbox.width  = stage_sz.width;
				letterbox.height = (int) (letterbox.width / src_aspect);
				letterbox.x = 0;
				letterbox.y = (stage_sz.height - letterbox.height) / 2;
			} else {
				letterbox.height = stage_sz.height;
				letterbox.width  = (int) (letterbox.height * src_aspect);
				letterbox.x = (stage_sz.width - letterbox.width) / 2;
				letterbox.y = 0;
			}

			return letterbox;
		}

		private void refresh_stage()
		{
			if (this.get_realized())
			{
				this.pixbuf = this.render_composite(Gdk.Rectangle() {
					width  = this.get_width(),
					height = this.get_height()
				});

				this.queue_draw();
			}
		}

		internal Gdk.Pixbuf render_composite(Gdk.Rectangle stage_sz)
		{
			var pixbuf_l = (this.frame_l != null && this.show_l) ? this.render_frame(this.frame_l, stage_sz) : new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, stage_sz.width, stage_sz.height);
			var pixbuf_r = (this.frame_r != null && this.show_r) ? this.render_frame(this.frame_r, stage_sz) : new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, stage_sz.width, stage_sz.height);

			if (this.method == AnaglyphMethod.NONE)
				return this.show_l ? pixbuf_l : pixbuf_r;

			return make_anaglyph(pixbuf_l, pixbuf_r, this.method, (float) this.red_coef);
		}

		internal static Gdk.Pixbuf render_frame(Frame frame, Gdk.Rectangle stage_sz)	/// Render the composition layer with the given frame
		{
			var render = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, stage_sz.width, stage_sz.height);

			if (frame.cache != null)
			{
				var letterbox = Stage.get_letterbox(frame.get_size(), stage_sz);
				var scaled = frame.cache.scale_simple(letterbox.width, letterbox.height, Gdk.InterpType.NEAREST);

				// Copy the appropriate part of the image with regards to frame offset
				var position = Gdk.Rectangle() {
					x = letterbox.x + (int) (frame.offset_x * letterbox.width),
					y = letterbox.y + (int) (frame.offset_y * letterbox.height),
					width  = letterbox.width,
					height = letterbox.height,
				};

				Gdk.Rectangle position_clipped;
				stage_sz.intersect(position, out position_clipped);

				scaled.copy_area(
					(position.x < position_clipped.x) ? (position_clipped.x - position.x) : 0,	// src_x
					(position.y < position_clipped.y) ? (position_clipped.y - position.y) : 0,	// src_y
					position_clipped.width,		// width
					position_clipped.height,	// height
					render,
					position_clipped.x,	// dest_x
					position_clipped.y	// dest_y
				);
			}

			return render;
		}

		/* Import/Export */

		public async void export_composite(File file, int qual)
		{
			Gdk.Pixbuf composite = this.render_composite(Gdk.Rectangle() {
				width  = this.frame_l.cache.width,
				height = this.frame_l.cache.height,
			});

			yield composite.save_to_streamv_async(yield file.create_async(FileCreateFlags.REPLACE_DESTINATION), "jpeg", {"quality"}, {qual.to_string()});
		}

		public async bool export_stereo(File file, int qual)
		{
			if (this.frame_l == null || this.frame_r == null)
				return false;

			var render_sz = Gdk.Rectangle() {
				width  = this.frame_l.cache.width,
				height = this.frame_l.cache.height,
			};

			Gdk.Pixbuf render_l = this.render_frame(this.frame_l, render_sz);
			Gdk.Pixbuf render_r = this.render_frame(this.frame_r, render_sz);

			var side_by_side = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, render_sz.width, render_l.height + render_r.height);
			render_l.copy_area(0, 0, render_l.width, render_l.height, side_by_side, 0, 0);
			render_r.copy_area(0, 0, render_r.width, render_r.height, side_by_side, 0, render_l.height);

			var out_stream = new MemoryOutputStream.resizable();
			yield side_by_side.save_to_streamv_async(out_stream, "jpeg", {"quality"}, {qual.to_string()});
			out_stream.close();

			owned uint8[] jpg_bytes_arr = out_stream.steal_data();
			jpg_bytes_arr.length = (int) out_stream.get_data_size ();

			var jpg_bytes = new ByteArray.take(jpg_bytes_arr);
			JPS.implant_jps_header(
				jpg_bytes,
				JPS.Info.MTYPE_STEREOSCOPIC_IMAGE |
				JPS.Info.LAYOUT_OVERUNDER |
				JPS.Info.LEFT_FIELD_FIRST
			);

			yield (yield file.create_async(FileCreateFlags.REPLACE_DESTINATION)).write_bytes_async(ByteArray.free_to_bytes(jpg_bytes));

			return true;
		}
	}

	namespace NativeFile
	{
		public async void load(File file, ListStore out_frames, out double fps)
		requires(out_frames.item_type == typeof(FlyBy.Frame))
		{
			bool present;
			var arch = new Gsf.InfileZip(new Gsf.InputStdio(file.get_path()));
			var media_dir = arch.child_by_name("media") as Gsf.InfileZip;

			/* Read manifest */
			var info_file = arch.child_by_name("info.json");

			var info_json = new uint8[info_file.size + 1];
			info_file.read((size_t) info_file.size, info_json);

			var parser = new Json.Parser.immutable_new();
			parser.load_from_data((string) info_json);
			var info = parser.get_root();

			var cur = new Json.Reader(info);

			if (cur.read_member("fps"))
				fps = cur.get_double_value();
			cur.end_member();

			/* Load frames */
			cur.read_member("frames");

			for (int i = 0; i < cur.count_elements(); i++)
			{
				//  yield;	// FIXME
				//  message(@"$(i)");
				var frame = new FrameInMem();

				cur.read_element(i);
					cur.read_member("filename");
					frame.filename = cur.get_string_value();
					cur.end_member();

					if (cur.read_member("hidden"))
						frame.hidden = cur.get_boolean_value();
					cur.end_member();

					if (cur.read_member("offset-x"))
						frame.offset_x = cur.get_double_value();
					cur.end_member();

					if (cur.read_member("offset-y"))
						frame.offset_y = cur.get_double_value();
					cur.end_member();
				cur.end_element();

				var img_file = media_dir.child_by_name(frame.filename);
				var img_file_data = new uint8[img_file.size + 1];
				img_file.read((size_t) img_file.size, img_file_data);

				frame.cache = new Gdk.Pixbuf.from_stream(new MemoryInputStream.from_data(img_file_data));
				out_frames.append(frame);
			}
			cur.end_member();
		}
	}

	enum AnimationState
	{
		ALTERNATING,
		NONE,
		PLAY_FWD,
		PLAY_BACKWD,
	}

	[GtkTemplate (ui = "/org/neocities/albertt/flyby/main.ui")]
	class MainWindow : Gtk.ApplicationWindow
	{
		uint advance_frame_cb_id = 0;	// If there's a timed callback automatically changing the current frame, store its ID here. (so that there aren't multiple such cb's at once)

		/* UI */
		[GtkChild]	Gtk.Box	stage_box;
			FlyBy.Stage	stage = new FlyBy.Stage();

		[GtkChild]	Gtk.Box	sidebar;
		[GtkChild]	Gtk.Label	drop_placeholder_label;
		[GtkChild]	Gtk.Stack	sidebar_stack;
		[GtkChild]	Gtk.ColumnView	frame_listview;

		[GtkChild]	Gtk.Box	media_bar;
		[GtkChild]	Gtk.ToggleButton	play_button;
		internal	StateMachine	anim_state {get;set;default = new StateMachine.with_edges_bidi(typeof(AnimationState), AnimationState.NONE, {
					AnimationState.NONE, AnimationState.ALTERNATING,
					AnimationState.NONE, AnimationState.PLAY_FWD,
					AnimationState.NONE, AnimationState.PLAY_BACKWD,
					AnimationState.PLAY_FWD, AnimationState.PLAY_BACKWD
				});}

		[GtkChild]	Gtk.Scale	position_scale;
		[GtkChild]	Gtk.Adjustment	position_adj;
		[GtkChild]	Gtk.SpinButton	fps_box;
		internal	double	fps { get; set; default = 12; }

		[GtkChild]	Gtk.ComboBoxText	ana_mode_box;
		[GtkChild]	Gtk.Adjustment	redboost_adj;
		[GtkChild]	Gtk.Switch	altern_switch;
		[GtkChild]	Gtk.ListBoxRow	altern_row;

		GLib.ListStore frames = new ListStore(typeof(FlyBy.Frame));
		Gtk.SingleSelection selection;

		public MainWindow(Gtk.Application app)
		{
			this.application = app;
			this.load_style();
		}

		private void load_style()
		{
			var css_provider = new Gtk.CssProvider();
			css_provider.load_from_resource("/org/neocities/albertt/flyby/style.css");
			Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}

		construct {
			bind_property("fps", fps_box, "value", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

			init_ui();
			init_animation();

			this.add_action_entries({
				{"open", () => {
					var d = new Gtk.FileChooserDialog("Open", this, Gtk.FileChooserAction.OPEN, "Cancel", Gtk.ResponseType.CANCEL, "_Open", Gtk.ResponseType.OK) {
						select_multiple = false,
						filter = App.ff_flyby,
					};
					d.show();

					d.response.connect((r) => {
						if (r == Gtk.ResponseType.OK)
							this.open.begin(d.get_file());

						d.close();
					});
				}, null, null, null},
				{"save-as", () => {
					var d = new Gtk.FileChooserDialog("Save As", this, Gtk.FileChooserAction.SAVE, "Cancel", Gtk.ResponseType.CANCEL, "Save As", Gtk.ResponseType.OK) {
						select_multiple = false,
						filter = App.ff_flyby
					};
					d.set_current_name(".flyby");
					d.show();

					d.response.connect((r) => {
						if (r == Gtk.ResponseType.OK)
							this.save.begin(d.get_file(), (_, ctx) => {
								this.save.end(ctx);
								message("Finished saving");
							});

						d.close();
					});
				}, null, null, null},
				{"export-composite", () => {
					var d = new Gtk.FileChooserDialog("Save As", this, Gtk.FileChooserAction.SAVE, "Cancel", Gtk.ResponseType.CANCEL, "Save As", Gtk.ResponseType.OK) {
						select_multiple = false
					};
					d.set_current_name(".jpeg");

					var ab = insert_footer(d);
					ab.pack_start(new Gtk.Label("Quality"));
					var qual_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1) {
						digits = 0,
						draw_value = true,
						value_pos = Gtk.PositionType.RIGHT,
						width_request = 150
					};
					qual_scale.adjustment.value = 90;
					ab.pack_start(qual_scale);
					d.show();

					d.response.connect((r) => {
						if (r == Gtk.ResponseType.OK)
							this.stage.export_composite(d.get_file(), (int) qual_scale.adjustment.value, (_, ctx) => {
								this.stage.export_composite.end(ctx);
								d.close();
							});

						d.close();
					});
				}, null, null, null},
				{"export-stereo", () => {
					var d = new Gtk.FileChooserDialog("Save As", this, Gtk.FileChooserAction.SAVE, "Cancel", Gtk.ResponseType.CANCEL, "Save As", Gtk.ResponseType.OK) {
						select_multiple = false
					};
					d.set_current_name(".jps");

					var ab = insert_footer(d);
					ab.pack_start(new Gtk.Label("Quality"));
					var qual_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1) {
						digits = 0,
						draw_value = true,
						value_pos = Gtk.PositionType.RIGHT,
						width_request = 150
					};
					qual_scale.adjustment.value = 90;
					ab.pack_start(qual_scale);
					d.show();

					d.response.connect((r) => {
						if (r == Gtk.ResponseType.OK)
							this.stage.export_stereo(d.get_file(), (int) qual_scale.adjustment.value, (_, ctx) => {
								this.stage.export_stereo.end(ctx);
								d.close();
							});

						d.close();
					});
				}, null, null, null},
				{"export-gif", () => {
					var d = new ExportGifDlg(this.frames, this.fps) {
						transient_for = this
					};
					d.show();
				}, null, null, null}
			}, this);

			this.frames.notify["n-items"].connect(() => {
				bool active = (this.frames.get_n_items() >= 2);

				foreach (string aname in this.list_actions())
					if (aname.has_prefix("export-"))
						(this.lookup_action(aname) as SimpleAction).set_enabled(active);
			});
			this.frames.notify_property("n-items");

			//
			var settings = new Settings ("org.neocities.albertt.flyby");
			settings.bind("red-boost", this.stage, "red-coef", SettingsBindFlags.DEFAULT);
		}

		void init_ui()
		{
			/* Global shortcuts */
			{
				var keypress = new Gtk.EventControllerKey();
				keypress.key_pressed.connect((keyval, keycode, mod_state) => {
					// New instance (Ctrl+n)
					if (keyval == Gdk.Key.n && (mod_state & Gdk.ModifierType.CONTROL_MASK) != 0)
					{
						this.application.activate();
						return true;
					}
					if (keyval == Gdk.Key.o && (mod_state & Gdk.ModifierType.CONTROL_MASK) != 0)
					{
						this.activate_action("open", null);
						return true;
					}
					if (keyval == Gdk.Key.s && (mod_state & Gdk.ModifierType.CONTROL_MASK) != 0)
					{
						this.activate_action("save-as", null);
						return true;
					}

					// Fullscreen (F11/Esc)
					if (keyval == Gdk.Key.F11 || (keyval == Gdk.Key.Escape && this.fullscreened))
					{
						this.fullscreened = !this.fullscreened;
						return true;
					}

					// Change anaglyph mode
					if (keyval == Gdk.Key.m)
					{
						this.ana_mode_box.active = (this.ana_mode_box.active + 1) % ((EnumClass) typeof(AnaglyphMethod).class_ref()).maximum;
						return true;
					}
					if (keyval == Gdk.Key.a)
					{
						if (this.anim_state.state == AnimationState.NONE)
							print("%b", this.anim_state.change_state(AnimationState.ALTERNATING));
						if (this.anim_state.state == AnimationState.ALTERNATING)
							this.anim_state.change_state(AnimationState.NONE);

						return true;
					}

					return false;
				});
				(this as Gtk.Widget).add_controller(keypress);
			}

			/* Frame list */
			{
				this.bind_property("fullscreened", this.sidebar, "visible", BindingFlags.INVERT_BOOLEAN);

				frames.notify["n-items"].connect(() => {
					sidebar_stack.visible_child = (Gtk.Widget) ((Gtk.StackPage) sidebar_stack.get_pages().get_item(frames.get_n_items() == 0 ? 0 : 1)).child;
				});

				var dnd_drop = new Gtk.DropTarget(Type.INVALID, Gdk.DragAction.COPY);
				dnd_drop.set_gtypes({typeof(Gdk.FileList)});
				dnd_drop.on_drop.connect((value, x, y) => {
					if (value.holds(typeof(Gdk.FileList)))
					{
						var files = (Gdk.FileList) value.get_boxed();
						bool at_least_one_file_matched = false;
						files.get_files().foreach((file) => {
							var file_info = file.query_info("standard::*", 0);
							if (App.ff_images.match(file_info))
							{
								this.frames.append(new FrameFromDisk(file));
								at_least_one_file_matched = true;
							}
							else if (App.ff_videos.match(file_info))
							{
								var dlg = new ImportVideoDlg(file) { transient_for = this };
								dlg.show();
								dlg.new_frame.connect(frame => this.frames.append(frame));
								dlg.new_fps.connect(new_fps => { this.fps = new_fps; });

								at_least_one_file_matched = true;
							}
						});
						return at_least_one_file_matched;
					}
					return false;
				});

				var keypress = new Gtk.EventControllerKey();
				keypress.key_pressed.connect((keyval, keycode, mod_state) => {
					if (keyval == Gdk.Key.Delete)
					{
						if (this.frames.get_n_items() > 0)
						{
							this.frames.remove(this.selection.selected);
							return true;
						}
					}
					return false;
				});

				this.sidebar_stack.add_controller(dnd_drop);
				this.frame_listview.add_controller(keypress);

				this.selection = new Gtk.SingleSelection(null) {
					autoselect = true,
					can_unselect = false,
					model = this.frames
				};

				this.frame_listview.model = this.selection;
				this.frame_listview.model.notify["selected-item"].connect(() => {
					// When the selected frame changes

					this.stage.frame_l = (this.frame_listview.model as Gtk.SingleSelection).selected_item as Frame;
					this.stage.frame_r = (Frame?) this.frame_listview.model.get_item((this.frame_listview.model as Gtk.SingleSelection).selected + 1);
				});
				this.frames.items_changed.connect((pos, removed, added) => {
					if (pos == this.selection.selected + 1)	// A change to the frame after the selected one should be paid as much attention to as a change to the actual selected one. Since both are used to create the anaglyph image.
						this.frame_listview.model.notify_property("selected-item");
				});

				this.frame_listview.append_column(new Gtk.ColumnViewColumn(null, null) {
					title = "Frame",
					expand = true,
					resizable = true,

					factory = new_signal_list_item_factory(
						(@this, li) => {
							li.child = new Gtk.Label(null) {
								halign = Gtk.Align.START,
								hexpand = true,
								ellipsize = Pango.EllipsizeMode.END
							};
							setup_row(li);
						},
						null,
						(@this, li) => {
							((Gtk.Label) li.child).label = ((FlyBy.Frame) li.item).get_display_name();

							ulong handler = ((FlyBy.Frame) li.item).notify["hidden"].connect(() => {
								if (((FlyBy.Frame) li.item).hidden == true)
								{
									li.child.add_css_class("hidden");
								}
								else
								{
									li.child.remove_css_class("hidden");
								}
							});
							li.set_data<ulong>("hidden-notify", handler);

							li.item.notify_property("hidden");
						},
						(@this, li) => {
							li.item.disconnect(li.get_data<ulong>("hidden-notify"));
						}
					)
				});
			}

			/* Play controls */
			{
				//  fps_box.output.connect(() => {
				//  	fps_box.set_text(@"$(fps_box.get_value()) fps");
				//  	return true;
				//  });

				this.anim_state.notify["state"].connect(() => {
					if (this.anim_state.state == AnimationState.PLAY_FWD || this.anim_state.state == AnimationState.PLAY_BACKWD)
					{
						this.play_button.icon_name = "media-playback-stop-symbolic";
						this.play_button.active = true;
					}
					else
					{
						this.play_button.icon_name = "media-playback-start-symbolic";
						this.play_button.active = false;
					}

					this.play_button.sensitive = this.anim_state.orthogonal_to(AnimationState.PLAY_FWD);
				});

				this.play_button.toggled.connect(() => {
					if (this.play_button.active)
						this.anim_state.change_state(AnimationState.PLAY_FWD);
					else
						this.anim_state.change_state(AnimationState.NONE);
				});

				this.selection.bind_property("selected", this.position_adj, "value", BindingFlags.BIDIRECTIONAL,
					(b, src, ref dst) => { dst.set_double((double) src.get_uint()); return true; },
					(b, src, ref dst) => { dst.set_uint((uint) src.get_double()); return true; }
				);
				this.frames.items_changed.connect(() => { this.position_adj.upper = (double) this.frames.get_n_items() - 1; });		// When the length changes
			}

			/* Stage */
			{
				this.stage_box.append(this.stage);

				this.frames.bind_property("n-items", this.stage, "visible", BindingFlags.SYNC_CREATE, (_, src, ref dst) => {	// Only show the stage when a frame can be selected. This lets us avoid a null frame state in FlyBy.Stage code
					dst.set_boolean(src.get_uint() > 0); return true;
				});

				this.ana_mode_box.bind_property("active", this.stage, "method", BindingFlags.BIDIRECTIONAL);
				this.ana_mode_box.active = 1;

				this.redboost_adj.bind_property("value", this.stage, "red-coef", BindingFlags.BIDIRECTIONAL);

				var scroll = new Gtk.EventControllerScroll(
					Gtk.EventControllerScrollFlags.VERTICAL |
					Gtk.EventControllerScrollFlags.DISCRETE
				);
				scroll.scroll.connect((dx, dy) => {
					this.position_adj.value += dy;

					return true;
				});

				this.stage.add_controller(scroll);
			}

			/* View menu */
			{
				altern_switch.state_set.connect(to_state => {
					if (to_state == false && this.anim_state.state == AnimationState.ALTERNATING)
					{
						this.anim_state.change_state(AnimationState.NONE);
						altern_switch.state = false;
					}
					if (to_state == true)
					{
						altern_switch.active = altern_switch.state = this.anim_state.change_state(AnimationState.ALTERNATING);
					}

					return true;
				});

				TestDataFunc refresh_can_animate = () => {
					this.altern_row.sensitive = this.anim_state.orthogonal_to(AnimationState.ALTERNATING) && this.stage.method == AnaglyphMethod.NONE;
				};
				refresh_can_animate();
				this.anim_state.notify["state"].connect(() => refresh_can_animate());
				this.stage.notify["method"].connect(() => refresh_can_animate());
			}

			/* Modal dialogs */
			//  this.export_dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL);
			//  this.export_start.connect(() => {
			//  	this.export_dialog.set_transient_for(this);
			//  	this.export_dialog.show();
			//  });
			//  this.export_finished.connect(() => {
			//  	this.export_dialog.set_transient_for(null);
			//  	this.export_dialog.hide();
			//  });
		}

		uint anim_cb_timer = 0;

		void advance_frame_recursive()
		{
			if (this.position_adj.value == this.position_adj.upper)
				this.anim_state.change_state(AnimationState.PLAY_BACKWD);
			if (this.position_adj.value == this.position_adj.lower)
				this.anim_state.change_state(AnimationState.PLAY_FWD);

			this.position_adj.value += (this.anim_state.state == AnimationState.PLAY_FWD) ? 1 : -1;

			anim_cb_timer = Timeout.add(
				(this.selection.selected_item as Frame).hidden ? 0 : (uint) (1000 / this.fps),
				() => { this.advance_frame_recursive(); return false; }
			);	// We need to renew this every time because they might have changed the fps setting while we were playing.
		}

		void alternate_frames_recursive()
		{
			if (this.stage.show_l)
			{
				this.stage.show_l = false;
				this.stage.show_r = true;
			}
			else
			{
				this.stage.show_l = true;
				this.stage.show_r = false;
			}

			anim_cb_timer = Timeout.add(
				(uint) (1000 / this.fps),
				() => { this.alternate_frames_recursive(); return false; }
			);	// We need to renew this every time because they might have changed the fps setting while we were playing.
		}

		void init_animation()
		{
			this.anim_state.on_transition(AnimationState.NONE, AnimationState.PLAY_FWD, () => { this.advance_frame_recursive(); return true; });

			SourceFunc stop_timer = () => {
				GLib.Source.remove(anim_cb_timer);
				return true;
			};
			this.anim_state.on_transition(AnimationState.PLAY_FWD, AnimationState.NONE, stop_timer);
			this.anim_state.on_transition(AnimationState.PLAY_BACKWD, AnimationState.NONE, stop_timer);

			this.anim_state.on_enter(AnimationState.ALTERNATING, () => {
				if (this.stage.method != AnaglyphMethod.NONE)
					return false;

				this.alternate_frames_recursive();
				return true;
			});
			this.anim_state.on_leave(AnimationState.ALTERNATING, () => {
				this.stage.show_l = true;
				this.stage.show_r = true;

				GLib.Source.remove(anim_cb_timer);
				return true;
			});
		}

		void setup_row(Gtk.ListItem li)
		{
			/* Row DnD */
			// FIXME: Why doesn't Gtk implement DnD of rows out-of-the-box!? Botched solution from: https://discourse.gnome.org/t/reorder-rows-in-a-list-gtk4/8422/4

			var row_drop = new Gtk.DropTarget(typeof(uint), Gdk.DragAction.MOVE);
			row_drop.on_drop.connect((value, x, y) => {
				if (value.holds(typeof(uint)))
				{
					uint idx_that = value.get_uint();
					uint idx_this;
					this.frames.find(li.item, out idx_this);

					var frame = this.frames.get_item(idx_that);
					this.frames.remove(idx_that);
					this.frames.insert(idx_this, frame);

					return true;
				}
				return false;
			});

			var row_drag = new Gtk.DragSource() { actions = Gdk.DragAction.MOVE };
			row_drag.prepare.connect(() => {
				uint idx_this;	// At the time of drag begin. The index will change, remember.
				this.frames.find(li.item, out idx_this);

				var idx_this_val = new Value(typeof(uint));
				idx_this_val.set_uint(idx_this);

				return new Gdk.ContentProvider.for_value(idx_this_val);
			});

			li.child.add_controller(row_drop);
			li.child.add_controller(row_drag);

			/* Right click menu */
			var popover = new Gtk.Popover();

			var rclick = new Gtk.GestureClick() {
				button = Gdk.BUTTON_SECONDARY,
			};
			rclick.pressed.connect((n, x, y) => {
				popover.set_pointing_to(Gdk.Rectangle() { x = (int) x, y = (int) y, width = 0, height = 0 });
				popover.popup();

				// For use in actions
				uint idx_this;
				this.frames.find(li.item, out idx_this);
				//  this.index_under_rclick = idx_this;
			});
			li.child.add_controller(rclick);

			// FIXME: How to do an actual context menu in Gtk4 that allows callbacks to code?
			//  var popover = new Gtk.PopoverMenu.from_model(
			//  	(new Gtk.Builder.from_resource("/org/neocities/albertt/flyby/menu_frame_listview.ui")).get_object("menu") as GLib.MenuModel
			//  ) {
			//  	has_arrow = false,
			//  	halign = Gtk.Align.START,
			//  };
			popover.set_parent(li.child);
			var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
			popover.child = box;
			var button = new Gtk.Button.with_label("Delete");
			box.append(button);
			button.clicked.connect(() => {
				popover.popdown();
				uint idx_this;
				this.frames.find(li.item, out idx_this);
				this.frames.remove(idx_this);
			});
			button = new Gtk.Button.with_label("Toggle hidden");
			box.append(button);
			button.clicked.connect(() => {
				popover.popdown();
				(li.item as Frame).hidden = !(li.item as Frame).hidden;
			});
		}

		/* Load/Save */

		public async void open(File file)
		{
			this.title = @"FlyBy – $(file.get_basename())";
			double _fps;

			yield FlyBy.NativeFile.load(file, this.frames, out _fps);

			this.fps = _fps;
		}

		public async void save(File file)
		{
			this.title = @"FlyBy – $(file.get_basename())";

			var arch = new Gsf.OutfileZip(new Gsf.OutputStdio(file.get_path()));

			/* Write manifest */
			var info_file = arch.new_child("info.json", false);

			Json.Builder builder = new Json.Builder ();
			{
				builder.begin_object ();

				builder.set_member_name ("fps");
				builder.add_double_value(this.fps);

				builder.set_member_name ("frames");
				builder.begin_array ();
				for (uint i = 0; i < this.frames.get_n_items(); i++)
				{
					var frame  = this.frames.get_item(i) as Frame;

					builder.begin_object();
						builder.set_member_name("filename");
						builder.add_string_value(frame.get_display_name());

						if (frame.hidden) {
							builder.set_member_name("hidden");
							builder.add_boolean_value(frame.hidden);
						}

						builder.set_member_name("offset-x");
						builder.add_double_value(frame.offset_x);

						builder.set_member_name("offset-y");
						builder.add_double_value(frame.offset_y);
					builder.end_object ();
				}
				builder.end_array ();

				builder.end_object ();
			}

			var gen = new Json.Generator() {
				root = builder.get_root(),
				pretty = true
			};

			info_file.puts(gen.to_data(null));
			info_file.close();

			/* Write media */
			arch.new_child("media", true);

			for (uint i = 0; i < this.frames.get_n_items(); i++)
			{
				Frame frame = this.frames.get_item(i) as Frame;
				Bytes frame_encoded = null;
				message("saving "+frame.get_display_name());

				if (frame is FrameFromDisk)
				{
					File source = (frame as FrameFromDisk).origin;
					string etag_out;
					frame_encoded = yield source.load_bytes_async(null, out etag_out);
				}
				else if (frame is FrameInMem)
				{
					uint8[] bytes = {};
					frame.cache.save_to_bufferv(out bytes, "jpeg", null, null);
					frame_encoded = new Bytes.take(bytes);
				}

				var dest = arch.new_child(@"media/$(frame.get_display_name())", false);

				dest.write(frame_encoded.get_data());
				dest.close();
			}

			arch.close();
		}
	}

	[GtkTemplate (ui = "/org/neocities/albertt/flyby/import_video.ui")]
	class ImportVideoDlg : Gtk.Dialog
	{
		[GtkChild]	Gtk.Picture	preview;
		[GtkChild]	Gtk.Box	resize_hole;
			ResolutionBox	resize;
		[GtkChild]	Gtk.SpinButton	skip;
		[GtkChild]	Gtk.Label	info_label;
		[GtkChild]	Gtk.ProgressBar	progress;
			uint	progress_updater_source_id;
		[GtkChild]	Gtk.Box	box;

		public ImportVideoDlg(File file)
		{
			Object(use_header_bar: 1);

			//  title = "Import video — " + file.get_basename();

			var btn_import = this.add_button("_Begin", Gtk.ResponseType.OK);
			var btn_cancel = this.add_button("_Cancel", Gtk.ResponseType.CANCEL);
			btn_import.add_css_class("suggested-action");

			skip.output.connect(() => {
				int interval_ms = skip.get_value_as_int();

				if (interval_ms == 0)
					skip.text = "All frames";
				else if (interval_ms < 1000)
					skip.text = @"Frame every $(interval_ms)ms";
				else
					skip.text = @"Frame every $((float) interval_ms / 1000)s";

				return true;
			});

			/* Init pipeline */
			this.create_pipeline(file);		// In pre-rolled state

			var first_frame = sample_to_pixbuf(appsink.pull_preroll());
			preview.paintable = Gdk.Texture.for_pixbuf(
				first_frame.scale_simple(
					(first_frame.width * 300) / first_frame.height,
					300,
					Gdk.InterpType.BILINEAR
				)
			);

			double fps;
			int64 vid_total_frames, duration_ns;
			this.get_vid_info(out fps, out vid_total_frames, out duration_ns);

			resize = new ResolutionBox(Gdk.Rectangle() { width = first_frame.width, height = first_frame.height });
			resize_hole.append(resize);

			/* Interactivity */

			// Label
			TestDataFunc update_label = () => {
				int64 no_frames = (skip.value == 0 ) ?
					vid_total_frames :
					(int64) (((double) vid_total_frames / fps) / (skip.value / 1000));

				int64 bytes = resize.size.width * resize.size.height * 3 * no_frames;

				info_label.label = @"<i>$no_frames frames @ $(resize.size.width)x$(resize.size.height) ≈ <b>$(bytes/1048576) MB memory</b></i>";
			};
			update_label();

			resize.notify["size"].connect(() => update_label());
			skip.notify["value"].connect(() => update_label());

			//

			var videosz_capf = ppl.get_by_name("videosz-capf");
			resize.notify["size"].connect(() => {
				videosz_capf.set_property("caps", Gst.Caps.from_string(@"video/x-raw,width=$(resize.size.width),height=$(resize.size.height)"));
			});

			var videofps_capf = ppl.get_by_name("videofps-capf");
			skip.notify["value"].connect(() => {
				videofps_capf.set_property("caps", Gst.Caps.from_string(skip.value == 0 ? "video/x-raw" : @"video/x-raw,framerate=1000/$((int) skip.value)"));
			});

			// Header buttons

			this.response.connect(id => {
				if (id == Gtk.ResponseType.CANCEL)
				{
					ppl.set_state(Gst.State.NULL);
					this.close();
				}
				if (id == Gtk.ResponseType.OK)
				{
					this.new_fps(skip.value == 0 ? fps : 1 / (skip.value / 1000));

					ppl.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT, 0);	// Flush the preroll frame from pipelne, we want it to have the same size as the others in case of resizing
					ppl.set_state(Gst.State.PLAYING);

					preview.opacity = 0.5;
					btn_import.sensitive = false;
					box.sensitive = false;
					progress.visible = true;

					this.progress_updater_source_id = Timeout.add(100, () => {
						int64 pos;
						if (ppl.query_position(Gst.Format.TIME, out pos)) {
							progress.fraction = (double) pos / duration_ns;
						}

						return true; // keep running
					});
				}
			});
		}

		~ImportVideoDlg()
		{
			GLib.Source.remove(this.progress_updater_source_id);
		}

		Gst.Pipeline ppl;
		Gst.App.Sink appsink;

		public signal void new_frame(Frame frame);
		public signal void new_fps(double fps);

		void create_pipeline(File file)
		{
			ppl = Gst.parse_launch("uridecodebin name=src ! videoconvert ! video/x-raw,format=RGB ! videoscale ! capsfilter name=videosz-capf caps=video/x-raw ! videorate ! capsfilter name=videofps-capf caps=video/x-raw ! appsink name=sink emit-signals=true sync=false max-buffers=100 drop=false") as Gst.Pipeline;

			ppl.get_by_name("src").set("uri", file.get_uri());
			appsink = ppl.get_by_name("sink") as Gst.App.Sink;

			int frame_no = 0;

			appsink.new_sample.connect(() => {
				var? sample = appsink.pull_sample();
				if (sample != null)
				{
						var frame = new FrameInMem() {
							filename = @"Frame $(frame_no++)",
							hidden = false,
							offset_x = 0,
							offset_y = 0
						};
						frame.cache = sample_to_pixbuf(sample);
						this.new_frame(frame);

				}

				return Gst.FlowReturn.OK;
			});

			ppl.set_state(Gst.State.PAUSED);

			// Wait until EOS or error
			var bus = ppl.get_bus();
			bus.add_signal_watch();
			bus.message.connect((bus, msg) => {
				switch (msg.type) {
					case Gst.MessageType.EOS:
						ppl.set_state(Gst.State.NULL);
						this.close();
						break;
					case Gst.MessageType.ERROR:
					{
						GLib.Error err;
						string debug;
						msg.parse_error(out err, out debug);

						ppl.set_state(Gst.State.NULL);
						this.close();

						var dlg = new Gtk.MessageDialog(this.transient_for, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "") {
							text = err.message,
							secondary_text = debug
						};
						dlg.show();
						dlg.response.connect(() => dlg.close());

						break;
					}
					default:
						break;
				}
			});
		}

		static Gdk.Pixbuf sample_to_pixbuf(Gst.Sample sample) throws Error
		{
			unowned var caps = sample.get_caps().get_structure(0);
			int width_px, height_px;
			caps.get_int("width", out width_px);
			caps.get_int("height", out height_px);

			var buf = sample.get_buffer();
			Gst.MapInfo map;

			if (buf.map(out map, Gst.MapFlags.READ))
			{
				var pixbuf = new Gdk.Pixbuf.from_bytes(new Bytes(map.data), Gdk.Colorspace.RGB, false, 8, width_px, height_px, width_px * 3);
				buf.unmap(map);
				return pixbuf;
			}

			throw new Error(0, 0, "Error converting GstSample to GdkPixbuf.");
		}

		void get_vid_info(out double fps, out int64 frame_count, out int64 duration_ns)	// ppl must be <=PAUSED to work
		{
			if (ppl.query_duration(Gst.Format.TIME, out duration_ns)) {
				// Get framerate from caps
				var sink_pad = ppl.get_by_name("sink").get_static_pad("sink");
				var caps = sink_pad.get_current_caps();
				unowned var s = caps.get_structure(0);

				int num, denom;
				if (s.get_fraction("framerate", out num, out denom)) {
					fps = (double) num / denom;
					double duration_sec = duration_ns / 1000000000.0;
					frame_count = (int64) (fps * duration_sec);
				}
			}
		}
	}

	class ExportGifDlg : Gtk.Dialog
	{
		Gtk.FileChooserWidget	fc;
		ResolutionBox	resize;

		GLib.ListModel frames;

		public ExportGifDlg(GLib.ListModel frames, double fps)
		{
			Object(use_header_bar: 1, modal: true, title: "Export Wiggle GIF");
			this.frames = frames;

			this.get_content_area().append(this.fc = new Gtk.FileChooserWidget(Gtk.FileChooserAction.SAVE) {
				select_multiple = false,
				vexpand = true
			});
			this.fc.set_current_name(".gif");

			var btn_export = this.add_button("_Export", Gtk.ResponseType.OK);
			var btn_cancel = this.add_button("_Cancel", Gtk.ResponseType.CANCEL);
			btn_export.add_css_class("suggested-action");

			var ab = insert_footer(this);
			ab.pack_start(new Gtk.Label("Size"));
			ab.pack_start(this.resize = new ResolutionBox(Gdk.Rectangle() {
				width  = (this.frames.get_object(0) as Frame).cache.width,
				height = (this.frames.get_object(0) as Frame).cache.height,
				}) { valign = Gtk.Align.CENTER, halign = Gtk.Align.START }
			);

			//  {
			//  	var midbox  = new Gtk.Box(Gtk.Orientation.VERTICAL, 0) { hexpand = true };

			//  	var scale_p = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, frames.get_n_items(), 1) {
			//  		//  restrict_to_fill_level = true
			//  	};
			//  	var scale_q = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, frames.get_n_items(), 1) {
			//  		inverted = true
			//  		//  restrict_to_fill_level = true
			//  	};

			//  	scale_p.adjustment.bind_property("value", scale_q, "fill-level");
			//  	scale_q.adjustment.bind_property("value", scale_p, "fill-level");

			//  	//  scale_q.adjustment.value = scale_q.adjustment.upper;

			//  	midbox.append(scale_p);
			//  	midbox.append(scale_q);

			//  	ab.set_center_widget(midbox);
			//  }

			/* Init pipeline */
			this.create_pipeline(fps);		// In pre-rolled state

			var videosz_capf = ppl.get_by_name("videosz-capf");
			resize.notify["size"].connect(() => {
				videosz_capf.set_property("caps", Gst.Caps.from_string(@"video/x-raw,width=$(resize.size.width),height=$(resize.size.height)"));
			});

			// Header buttons
			this.response.connect((r) => {
				if (r == Gtk.ResponseType.OK)
				{
					this.get_content_area().sensitive = false;
					btn_export.sensitive = false;

					filesink.set("location", this.fc.get_file().get_path());
					ppl.set_state(Gst.State.PLAYING);
				}
				else
				{
					ppl.set_state(Gst.State.NULL);
					this.close();
				}
			});
		}

		Gst.Pipeline ppl;
		Gst.App.Src appsrc;
		Gst.Element filesink;

		delegate void PushFrameNFn(uint n);

		void create_pipeline(double fps)
		{
			var render_size = (this.frames.get_object(0) as Frame).get_size();

			ppl = Gst.parse_launch(
				"appsrc block=false name=src" +
				@" caps=video/x-raw,width=$(render_size.width),height=$(render_size.height),format=RGB,framerate=$((int) fps)/1 " +
				"! videoscale ! capsfilter name=videosz-capf caps=video/x-raw " +
				"! gifenc repeat=-1 ! filesink name=sink"
			) as Gst.Pipeline;

			filesink = ppl.get_by_name("sink");
			appsrc   = ppl.get_by_name("src") as Gst.App.Src;

			uint n_frames = this.frames.get_n_items();
			uint n_frames_sent = 0;
			PushFrameNFn push_frame_n = (i) =>
			{
				var frame = this.frames.get_object(i < n_frames ? i : 2*n_frames - i - 1) as Frame;

				if (frame.hidden)
					return;

				var buffer = new Gst.Buffer.wrapped_bytes(
					Stage.render_frame(frame, render_size).pixel_bytes
				);
				buffer.pts = Gst.MSECOND * (Gst.ClockTime) (1000 / fps) * n_frames_sent++;

				appsrc.push_buffer(buffer);
			};

			appsrc.need_data.connect(() => {
				uint i = 0;

				while (i < n_frames)
					push_frame_n(i++);
				i--;
				while (--i > 0)
					push_frame_n(i);

				appsrc.end_of_stream();
			});

			// Wait until EOS or error
			var bus = ppl.get_bus();
			bus.add_signal_watch();
			bus.message.connect((bus, msg) => {
				switch (msg.type) {
					case Gst.MessageType.EOS:
						this.close();
						break;
					case Gst.MessageType.ERROR:
					{
						GLib.Error err;
						string debug;
						msg.parse_error(out err, out debug);

						this.close();

						var dlg = new Gtk.MessageDialog(this.transient_for, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "") {
							text = err.message,
							secondary_text = debug
						};
						dlg.show();
						dlg.response.connect(() => dlg.close());

						break;
					}
					default:
						break;
				}
			});
		}
	}

	private class ResolutionBox : Gtk.Box
	{
		Gtk.ComboBoxText combo;
		Gdk.Rectangle orig_sz;

		public Gdk.Rectangle size { get; private set; }

		public ResolutionBox(Gdk.Rectangle orig_sz)
		{
			this.orig_sz = orig_sz;
			combo.active = 0;
		}

		construct {
			combo = new Gtk.ComboBoxText.with_entry();

			combo.append_text("Don't resize");
			combo.append_text("360p");
			combo.append_text("720p");
			combo.append_text("1080p");

			combo.changed.connect(this.combo_changed);

			append(combo);
		}

		void combo_changed()
		{
			int active = combo.active;

			if (active == -1)
			{
				/* Try to parse */
				var text = combo.get_active_text().dup();

				MatchInfo match;
				if (/^\s*(\d+)\s*x\s*(\d+)\s*$/.match(text, 0, out match))
				{
					this.size = Gdk.Rectangle() {
						width  = int.parse(match.fetch(1)),
						height = int.parse(match.fetch(2))
					};

					return;
				}
				else
					active = 0;
			}

            var new_sz = Gdk.Rectangle();
            bool swapped = false;

            int src_w = orig_sz.width;
            int src_h = orig_sz.height;

            // normalise so width >= height
            if (src_h > src_w)
            {
                swapped = true;
                var tmp = src_h;
                src_h = src_w;
                src_w = tmp;
            }

            switch (active)
            {
                case 0:
                    new_sz.width  = src_w;
                    new_sz.height = src_h;
                    break;

                case 1:
                    new_sz.height = 360;
                    new_sz.width  = (src_w * new_sz.height) / src_h;
                    break;

                case 2:
                    new_sz.height = 720;
                    new_sz.width  = (src_w * new_sz.height) / src_h;
                    break;

                case 3:
                    new_sz.height = 1080;
                    new_sz.width  = (src_w * new_sz.height) / src_h;
                    break;
            }

            // restore original orientation *only if we actually swapped*
            if (swapped)
            {
                var tmp = new_sz.height;
                new_sz.height = new_sz.width;
                new_sz.width = tmp;
            }

            this.size = new_sz;
		}
	}
}
