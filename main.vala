// https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/tree/main/video/gtk4
// https://packages.debian.org/sid/gstreamer1.0-gtk4

// seamless loop: https://stackoverflow.com/questions/53747278/seamless-video-loop-in-gstreamer
// backwards: https://gstreamer.freedesktop.org/documentation/additional/design/trickmodes.html?gi-language=c
// images in Gtk frames: https://stackoverflow.com/questions/70921068/drag-and-drop-with-gtk4-connecting-dragsource-and-droptarget-via-contentprovide

namespace FlyBy
{
	public class App : Gtk.Application {
		public App () {
			Object(
				application_id: "com.github.albert-tomanek.flyby",
				flags: ApplicationFlags.FLAGS_NONE
			);
		}

		protected override void activate () {
			var win = new FlyBy.MainWindow(this);
			win.show ();

			this.add_window(win);
			win.show();
		}

		public static int main(string[] args)
		{
			Gst.init(ref args);

			var app = new App();
			return app.run(args);
		}

		// Useful stuff

		public static Gtk.FileFilter ff_images;
		public static Gtk.FileFilter ff_videos;
	
		static construct {
			ff_images = new Gtk.FileFilter() { name = "All image formats" };
			ff_images.add_mime_type("image/jpeg");
			ff_images.add_mime_type("image/png");
		}	
	}

	class Frame : Object
	{
		public Gdk.Pixbuf? cache { get; private set; default = null; }
		public File origin { get; construct set; }

		public Frame.from_path(string path)
		{
			Object(origin: File.new_for_path(path));
		}
	}

	[GtkTemplate (ui = "/com/github/albert-tomanek/flyby/main.ui")]
	class MainWindow : Gtk.ApplicationWindow
	{
		/* UI */
		[GtkChild] Gtk.Box          stage;

		[GtkChild] Gtk.ColumnView     frame_listview;

		[GtkChild] Gtk.Box          media_bar;
		[GtkChild] Gtk.ToggleButton play_button;
		[GtkChild] Gtk.Scale        position_scale;
		[GtkChild] Gtk.Adjustment   position_adj;
		
		[GtkChild] Gtk.Adjustment   framediff_adj;
		[GtkChild] Gtk.Scale        framediff_scale;
		[GtkChild] Gtk.ComboBoxText ana_mode_box;
		[GtkChild] Gtk.Adjustment   redboost_adj;

		[GtkChild] Gtk.Button       export_button;
		[GtkChild] Gtk.Dialog       export_dialog;
		[GtkChild] Gtk.ProgressBar  export_progressbar;

		/* Gst */
		Gst.Pipeline pipeline;
		Gst.Bin      export_bin;
		Gst.Element  export_tee;
		Gst.Pad?     export_tee_pad = null;
		Gst.Element  src;
		Gst.Element  sink;
		Gst.Element  anablend;
		Gst.Pad      delay_pad_l;
		Gst.Pad      delay_pad_r;
		
		GLib.ListStore frames = new ListStore(typeof(FlyBy.Frame));

		Gst.ClockTime duration;
		Gst.ClockTime position;
		//  Gst.ClockTime position {
		//  	get {
		//  		Gst.ClockTime pos;
		//  		this.pipeline.query_position(Gst.Format.PERCENT, out pos);
		//  		return pos;
		//  	}
		//  }

		signal void export_start(string path);
		signal void export_finished();
		signal void new_source();

		public MainWindow(Gtk.Application app)
		{
			this.application = app;
			this.load_style();
		}

		private void load_style()
		{
			var css_provider = new Gtk.CssProvider();
			css_provider.load_from_resource("/com/github/albert-tomanek/flyby/style.css");
			Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}
		
		construct {
			init_pipeline();

			/* Application states */
			this.export_start.connect((path) => {
				pipeline.set_state(Gst.State.PAUSED);
				this.export_bin.get_by_name("filesink").set("location", path);
				this.add_export_branch();
				this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, 0, Gst.SeekType.NONE, 0));
				pipeline.set_state(Gst.State.PLAYING);
			});
			this.export_finished.connect(this.remove_export_branch);

			connect_pipeline_to_ui();		
			init_ui();

			//  import_video("/home/albert/Videos/exercise.mp4");
		}

		void init_pipeline()
		{
			/* Create pipeline */
			this.pipeline   = Gst.parse_launch("uridecodebin name=src ! videoconvert ! videoscale ! video/x-raw,width=720,height=480 ! tee name=t ! queue name=queue_l ! anablend name=blend method=1 t. ! queue name=queue_r ! blend. blend. ! tee name=export_tee ! queue ! videoconvert ! clappersink name=sink") as Gst.Pipeline;
			this.pipeline.get_bus().add_signal_watch(1);
			this.export_bin = Gst.parse_bin_from_description("videoconvert name=first ! x264enc tune=zerolatency ! mp4mux ! filesink name=filesink", false) as Gst.Bin;

			this.sink        = this.pipeline.get_by_name("sink");
			this.src         = this.pipeline.get_by_name("src");
			this.anablend    = this.pipeline.get_by_name("blend");
			this.export_tee  = this.pipeline.get_by_name("export_tee");
			this.delay_pad_l = this.pipeline.get_by_name("queue_l").sinkpads.first().data;
			this.delay_pad_r = this.pipeline.get_by_name("queue_r").sinkpads.first().data;

			{
				Gtk.Widget clappersink_widget;
				this.sink.get("widget", out clappersink_widget);
				this.stage.append(clappersink_widget);
			}
			
			pipeline.set_state(Gst.State.NULL);
		}

		void connect_pipeline_to_ui()
		{
			/* Duration & progress */
			this.new_source.connect(() => {
				unowned string? uri;
				this.src.get("uri", out uri);
				var info = (new Gst.PbUtils.Discoverer(1 * Gst.SECOND)).discover_uri(uri);
				this.duration = info.get_duration();
			});
			//  this.position_scale.change_value.connect((type, set_to) => {
			//  	int64 time = (int64) (set_to * 1000000);
			//  	message(@"seek $set_to");
			//  	this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.PERCENT, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, time, Gst.SeekType.NONE, 0));
			//  });
			this.sink.get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER, (pad, info) => {
				/* Slider gets adjusted every time the next buffer is displayed */

				var buf = info.get_buffer();

				if (buf != null)
				{
					var position = buf.pts;
					//  message(@"$(this.position_adj.lower)\t$(this.position_adj.value)\t$(this.position_adj.upper)");
					//  this.position_scale.set_value(((double) position) / ((double) this.duration));	// FIXME
				}
				return Gst.PadProbeReturn.PASS;
			});		
		}

		void init_ui()
		{
			this.anablend.bind_property("method", this.ana_mode_box, "active", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
			this.redboost_adj.notify["value"].connect(() => {
				this.anablend.set("red_coef", this.redboost_adj.value);
				_botched_flush_pipeline();
			});
			this.src.bind_property("uri", this.export_button, "sensitive", BindingFlags.SYNC_CREATE, (b, from, ref to) => { to.set_boolean(from.get_string() != null); return true; });

			/* Play button */
			this.src.bind_property("uri", this.play_button, "sensitive", BindingFlags.SYNC_CREATE, (b, from, ref to) => { to.set_boolean(from.get_string() != null); return true; });
			this.play_button.notify["active"].connect(() => {
				if (this.play_button.active)
				{
					pipeline.set_state(Gst.State.PLAYING);
					this.play_button.icon_name = "media-playback-pause-symbolic";
				}
				else
				{
					pipeline.set_state(Gst.State.PAUSED);
					this.play_button.icon_name = "media-playback-start-symbolic";
				}
			});

			this.sink.get_static_pad("sink").add_probe(Gst.PadProbeType.EVENT_DOWNSTREAM, (pad, info) => {
				var event = info.get_event();

				if (event != null)
				{
					if (event.type == Gst.EventType.EOS)
					{
						//  if (this.export_branch_connected)
						//  	this.remove_export_branch();

						// Play backwardss
						//  this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(-1.0, Gst.Format.UNDEFINED, Gst.SeekFlags.FLUSH, Gst.SeekType.NONE, 0, Gst.SeekType.NONE, 0));
						//  //  this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, 0, Gst.SeekType.NONE, 0));
						//  return Gst.PadProbeReturn.HANDLED;
					}
				}
				return Gst.PadProbeReturn.PASS;
			});
			this.sink.get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER/* | Gst.PadProbeType.EVENT_DOWNSTREAM*/, (pad, info) => {
				//  if (info.get_event() != null)
				//  {
				//  	if (info.get_event().type == Gst.EventType.EOS) {
				//  		// EOS event received, but the sink element is still processing buffers
				//  		return Gst.PadProbeReturn.OK;
				//  	}
				//  }
			
				// Check if the buffer is empty
				var buffer = info.get_buffer();
				if (buffer == null || buffer.get_size() == 0) {
					message("No more buffers.");
					if (this.export_branch_connected)
						this.export_finished();
					this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, 0, Gst.SeekType.NONE, 0));
				}
			
				return Gst.PadProbeReturn.OK;
			});
			this.pipeline.get_bus().message["state-changed"].connect((msg) => {
				Gst.State new_state;
				msg.parse_state_changed(null, out new_state, null);

				//  message(@"$new_state", new_state);
				this.play_button.active = (new_state == Gst.State.PLAYING);
			});
			this.on_frame_difference_changed();

			/* Frame list */
			var dnd_drop = new Gtk.DropTarget(Type.INVALID, Gdk.DragAction.COPY);
			dnd_drop.set_gtypes({typeof(Gdk.FileList)});
			dnd_drop.on_drop.connect((value, x, y) => {
				if (value.holds(typeof(Gdk.FileList)))
				{
					var files = (Gdk.FileList) value.get_boxed();
					bool at_least_one_matched = false;
					files.get_files().foreach((file) => {
						var file_info = file.query_info("standard::*", 0);
						if (App.ff_images.match(file_info))
						{					
							this.frames.append(new Frame(){ origin = file });
							at_least_one_matched = true;
						}
					});
					return at_least_one_matched;
				}
				return false;
			});

			this.frame_listview.add_controller(dnd_drop);

			this.frame_listview.model = new Gtk.SingleSelection(null) {
				autoselect = true,
				can_unselect = false,
				model = this.frames
			};

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
						((Gtk.Label) li.child).label = ((FlyBy.Frame) li.item).origin.get_basename();
					},
					null
				)
			});	

			/* Modal dialogs */
			this.export_dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL);
			this.export_start.connect(() => {
				this.export_dialog.set_transient_for(this);
				this.export_dialog.show();
			});
			this.export_finished.connect(() => {
				this.export_dialog.set_transient_for(null);
				this.export_dialog.hide();
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
			});
			li.child.add_controller(rclick);
			
			// FIXME: How to do an actual context menu in Gtk4 that allows callbacks to code?
			//  var popover = new Gtk.PopoverMenu.from_model(
			//  	(new Gtk.Builder.from_resource("/com/github/albert-tomanek/flyby/menu_frame_listview.ui")).get_object("menu") as GLib.MenuModel
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
		}

		/* UI callbacks */
		[GtkCallback]
		void on_import()
		{
			var d = new Gtk.FileChooserDialog("Open video file", this, Gtk.FileChooserAction.OPEN, "Cancel", Gtk.ResponseType.CANCEL, "Open", Gtk.ResponseType.OK) {
				select_multiple = false,
				filter = new Gtk.FileFilter() {
					name = "MP4 files",
				},
			};
			d.filter.add_pattern("*.mp4");
			
			d.show();

			d.response.connect((r) => {
				if (r == Gtk.ResponseType.OK)
					import_video(d.get_file().get_path());

				d.close();
			});
			//  this.reset_adjustment();
		}

		void import_video(string path)
		{
			pipeline.set_state(Gst.State.NULL);
			this.src.set("uri", "file://" + path);
			pipeline.set_state(Gst.State.PAUSED);
			this.new_source();
		}

		[GtkCallback]
		void on_export()
		{
			/* Pick save location */
			var d = new Gtk.FileChooserDialog("Export to file", this, Gtk.FileChooserAction.SAVE, "Cancel", Gtk.ResponseType.CANCEL, "Save", Gtk.ResponseType.OK) {
				select_multiple = false,
				filter = new Gtk.FileFilter() {
					name = "MP4 files",
				},
			};
			d.filter.add_pattern("*.mp4");
			
			d.show();

			d.response.connect((r) => {
				if (r == Gtk.ResponseType.OK)
					this.export_start(d.get_file().get_path());

				d.close();
			});
		}

		[GtkCallback]
		void on_export_dialog_response(int response)
		{
			if (response == Gtk.ResponseType.CANCEL)
			{
				this.pipeline.get_by_name("src").send_event(new Gst.Event.eos());
				this.export_finished();
			}
		}

		void add_export_branch()
		{
			// Uhh godd: https://stackoverflow.com/questions/74991007/gstreamer-dynamically-link-a-tee-while-pipline-is-playing
			// Steps detailed here: https://raw.githubusercontent.com/genesi/gstreamer/master/docs/design/part-block.txt
			// https://stackoverflow.com/questions/74932282/gstreamer-activate-deactivate-a-specific-tee-src-at-runtime/74932832#74932832

			this.pipeline.add(this.export_bin);
			this.export_tee.link(this.export_bin.get_by_name("first"));
			this.export_bin.sync_state_with_parent();

			//  this.export_tee_pad = this.export_tee.get_request_pad("src_%u");
			//  this.export_bin.link_pads(this.export_tee);
		}

		void remove_export_branch()
		{
			// Assume state is NULL

			this.export_tee.unlink(this.export_bin.get_by_name("first"));
			this.pipeline.remove(this.export_bin);
			//  this.export_bin.unlink(this.export_tee_pad);
			//  this.export_tee.release_request_pad(this.export_tee_pad);
			//  this.export_tee_pad = null;
		}

		bool export_branch_connected {
			get {
				return this.export_bin.get_by_name("first").get_static_pad("sink").is_linked();
			}
		}

		//  void export_to_file(string path)
		//  {
		//  	/* Start Export */
			
			
		//  	pipeline.set_state(Gst.State.NULL);
		//  	var tee_pad = this.export_tee.get_request_pad('src_%u');
		//  	export_bin.link(tee_pad);


		//  	/* Show dialog */

		//  	var d = new Gtk.Dialog.with_buttons("Exporting Video", this, Gtk.DialogFlags.MODAL | Gtk.DialogFlags.USE_HEADER_BAR, "Cancel", Gtk.ResponseType.CANCEL);
		//  	var prog = new Gtk.ProgressBar() {
		//  		show_text = true,
		//  		text = "Exporting...",
		//  		fraction = 0.4,
		//  	};
		//  	d.set_child(prog);
		//  	d.show();

		//  	d.response.connect((r) => {
		//  		if (r == Gtk.ResponseType.CANCEL)
		//  		{
		//  			/* Cancel export */
		//  			d.close();
		//  		}
		//  	});

		//  	/* Connect the two */
		//  	var bus = this.pipeline.get_bus();
		//  	bus.add_signal_watch();
		//  	ulong cb_handle = bus.message.connect((m) => {
		//  		if (m.type == Gst.MessageType.EOS)
		//  		{
					//  export_bin.unlink(tee_pad);
					//  this.export_tee.release_request_pad(tee_pad);

		//  			Signal.remove_emission_hook(bus.message, cb_handle);
		//  		}
		//  	});
		//  }

		[GtkCallback]
		void on_frame_difference_changed()
		{
			this.delay_pad_l.offset = (int64) ( double.max(0, this.framediff_adj.value) * 100000);
			this.delay_pad_r.offset = (int64) (-double.min(0, this.framediff_adj.value) * 100000);

			_botched_flush_pipeline();
		}

		void reset_adjustment()
		{
			int fps_num, fps_denom;
			this.delay_pad_l.get_current_caps().get_structure(0).get_fraction("framerate", out fps_num, out fps_denom);
			double fps = ((double) fps_num) / ((double) fps_denom);

			this.framediff_adj.lower = -(2 * fps);
			this.framediff_adj.upper =  (2 * fps);
			this.framediff_adj.value =  0.2 * fps;	// default diff = 200ms

			this.framediff_scale.clear_marks();
			
			for (double i = -2*fps; i <= 2*fps; i += 1/fps)
			{
				this.framediff_scale.add_mark(i, Gtk.PositionType.BOTTOM, i == 0 ? "0" : null);
				message("%f", (float)i);
			}
		}

		void _botched_flush_pipeline()
		{
			/* FIXME: I know it's stupid, but we get the current playback time and seek to it (in order to flush). */
			Gst.State state;
			this.pipeline.get_state(out state, null, Gst.CLOCK_TIME_NONE);
			
			var query = new Gst.Query.position(Gst.Format.TIME);
			if (pipeline.query(query))
			{
				int64 time;
				query.parse_position(null, out time);
				this.pipeline.get_by_name("sink").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.ACCURATE | Gst.SeekFlags.FLUSH, Gst.SeekType.SET, time, Gst.SeekType.NONE, 0));
			}

			this.pipeline.set_state(state);
		}
	}
}