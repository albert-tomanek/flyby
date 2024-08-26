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
		public static Gtk.FileFilter ff_flyby;
	
		static construct {
			ff_images = new Gtk.FileFilter() { name = "All image formats" };
			ff_images.add_mime_type("image/jpeg");
			ff_images.add_mime_type("image/png");

			ff_flyby = new Gtk.FileFilter() { name = "FlyBy files" };
			ff_flyby.add_pattern("*.flyby");
		}	
	}

	abstract class Frame : Object
	{
		public Gdk.Pixbuf? cache { get; set; default = null; }

		public bool hidden { get; set; default = false; }

		public abstract string get_name();
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

		public override string get_name()
		{
			return this.origin.get_basename();
		}
	}

	class FrameInMem : Frame
	{
		public string filename { get; set; }

		public override string get_name()
		{
			return this.filename;
		}
	}

	[GtkTemplate (ui = "/com/github/albert-tomanek/flyby/main.ui")]
	class MainWindow : Gtk.ApplicationWindow
	{
		/* UI */
		[GtkChild] Gtk.Box          stage;
		[GtkChild] Gtk.Picture      view;

		[GtkChild] Gtk.ColumnView   frame_listview;

		[GtkChild] Gtk.Box          media_bar;
		[GtkChild] Gtk.ToggleButton play_button;
		           int              play_state;		// -1 = advancing backward, 0 = not playing, 1 = advancing forward
		[GtkChild] Gtk.Scale        position_scale;
		[GtkChild] Gtk.Adjustment   position_adj;
		[GtkChild] Gtk.Adjustment   fps_adj;
		
		[GtkChild] Gtk.Adjustment   framediff_adj;
		[GtkChild] Gtk.Scale        framediff_scale;
		[GtkChild] Gtk.ComboBoxText ana_mode_box;
		[GtkChild] Gtk.Adjustment   redboost_adj;

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
		Gtk.SingleSelection selection;
		Binding? current_frame_cache_binding = null;

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
			init_ui();

			this.add_action_entries({
				{"save-as", () => {
					var d = new Gtk.FileChooserDialog("Save As", this, Gtk.FileChooserAction.SAVE, "Cancel", Gtk.ResponseType.CANCEL, "Save As", Gtk.ResponseType.OK) {
						select_multiple = false,
						filter = App.ff_flyby
					};					
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
				{"open", () => {
					var d = new Gtk.FileChooserDialog("Open", this, Gtk.FileChooserAction.OPEN, "Cancel", Gtk.ResponseType.CANCEL, "_Open", Gtk.ResponseType.OK) {
						select_multiple = false,
						filter = App.ff_flyby,
					};
					d.show();
		
					d.response.connect((r) => {
						if (r == Gtk.ResponseType.OK)
							this.open.begin(d.get_file(), (_, ctx) => {
								this.open.end(ctx);
							});
		
						d.close();
					});
				}, null, null, null}
			}, this);
		}

		void init_ui()
		{
			//  this.anablend.bind_property("method", this.ana_mode_box, "active", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
			this.redboost_adj.notify["value"].connect(() => {
				this.anablend.set("red_coef", this.redboost_adj.value);
				_botched_flush_pipeline();
			});

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
							this.frames.append(new FrameFromDisk(file));
							at_least_one_matched = true;
						}
					});
					return at_least_one_matched;
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

			this.frame_listview.add_controller(dnd_drop);
			this.frame_listview.add_controller(keypress);

			this.selection = new Gtk.SingleSelection(null) {
				autoselect = true,
				can_unselect = false,
				model = this.frames
			};

			this.frame_listview.model = this.selection;
			this.frame_listview.model.notify["selected-item"].connect(() => {
				// When the selected frame changes

				// Stop listening to changes in the old frame.
				if (current_frame_cache_binding != null)
					current_frame_cache_binding.unbind();

				// Loading is async so we actually have to wait until the property appears
				current_frame_cache_binding = ((this.frame_listview.model as Gtk.SingleSelection).selected_item as Frame).bind_property(
					"cache",
					this.view,
					"paintable",
					BindingFlags.SYNC_CREATE,
					(b, src, ref dest) => {
						if (src.get_object() != null)	// May still be loading
							dest.set_object(Gdk.Texture.for_pixbuf(src.get_object() as Gdk.Pixbuf));
						return true;
					}
				);
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
						((Gtk.Label) li.child).label = ((FlyBy.Frame) li.item).get_name();

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

			/* Play controls */
			this.play_button.notify["active"].connect(() => {
				if (this.play_button.active)
				{
					this.play_button.icon_name = "media-playback-stop-symbolic";
					this.play_state = 1;
					Timeout.add(
						(uint) (1000 / this.fps_adj.value),
						() => { this.advance_frame_recursive(); return false; }
					);
				}
				else
				{
					this.play_button.icon_name = "media-playback-start-symbolic";
					this.play_state = 0;	// advance_frame_recursive will stop by itself
				}
			});
			this.selection.bind_property("selected", this.position_adj, "value", BindingFlags.BIDIRECTIONAL,
				(b, src, ref dst) => { dst.set_double((double) src.get_uint()); return true; },
				(b, src, ref dst) => { dst.set_uint((uint) src.get_double()); return true; }
			);
			this.frames.items_changed.connect(() => { this.position_adj.upper = (double) this.frames.get_n_items() - 1; });		// When the length changes

			/* Stage */
			var scroll = new Gtk.EventControllerScroll(
				Gtk.EventControllerScrollFlags.VERTICAL |
				Gtk.EventControllerScrollFlags.DISCRETE
			);
			scroll.scroll.connect((dx, dy) => {
				this.position_adj.value += dy;

				return true;
			});

			this.stage.add_controller(scroll);
			
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

		void advance_frame_recursive()
		{
			if (this.position_adj.value == this.position_adj.upper || this.position_adj.value == this.position_adj.lower)
				this.play_state = -this.play_state;

			this.position_adj.value += this.play_state;	// either 1 or -1

			if (this.play_state != 0)	// If it is, they've asked us to stop.
				Timeout.add(
					(this.selection.selected_item as Frame).hidden ? 0 : (uint) (1000 / this.fps_adj.value),
					() => { this.advance_frame_recursive(); return false; }
				);	// We need to renew this every time because they might have changed the fps setting while we were playing.
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
			button = new Gtk.Button.with_label("Toggle hidden");
			box.append(button);
			button.clicked.connect(() => {
				popover.popdown();
				(li.item as Frame).hidden = !(li.item as Frame).hidden;
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

		/* Load/Save */

		async void open(File file)
		{
			message(@"open $(file.get_path())");
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
			
			/* Load frames */
			cur.read_member("frames");

			for (int i = 0; i < cur.count_elements(); i++)
			{
				//  yield;	// FIXME
				message(@"$(i)");
				var frame = new FrameInMem();

				cur.read_element(i);
					cur.read_member("filename");
					frame.filename = cur.get_string_value();
					cur.end_member();
					cur.read_member("hidden");
					frame.hidden = cur.get_boolean_value();
					cur.end_member();
				cur.end_element();
				
				var img_file = media_dir.child_by_name(frame.filename);
				var img_file_data = new uint8[img_file.size + 1];
				img_file.read((size_t) img_file.size, img_file_data);

				frame.cache = new Gdk.Pixbuf.from_stream(new MemoryInputStream.from_data(img_file_data));
				this.frames.append(frame);
			}
			cur.end_member();
		}

		async void save(File file)
		{
			var arch = new Gsf.OutfileZip(new Gsf.OutputStdio(file.get_path()));

			/* Write manifest */
			var info_file = arch.new_child("info.json", false);

			Json.Builder builder = new Json.Builder ();
			{
				builder.begin_object ();

				builder.set_member_name ("frames");
				builder.begin_array ();
				for (uint i = 0; i < this.frames.get_n_items(); i++)
				{
					var frame  = this.frames.get_item(i) as Frame;

					builder.begin_object();
					builder.set_member_name("filename");
					builder.add_string_value(frame.get_name());
					builder.set_member_name("hidden");
					builder.add_boolean_value(frame.hidden);
					builder.end_object ();
				}
				builder.end_array ();

				builder.end_object ();
			}

			var gen = new Json.Generator() { root = builder.get_root() };

			info_file.puts(gen.to_data(null));
			info_file.close();

			/* Write media */
			arch.new_child("media", true);

			for (uint i = 0; i < this.frames.get_n_items(); i++)
			{
				Frame frame = this.frames.get_item(i) as Frame;
				Bytes frame_encoded = null;
				message("saving "+frame.get_name());

				if (frame is FrameFromDisk)
				{
					File source = (frame as FrameFromDisk).origin;
					string etag_out;
					frame_encoded = yield source.load_bytes_async(null, out etag_out);

					//  var data = Gsf.StructuredBlob.read(Gst.Input.mmap_new(source.get_path()));
					//  data.write(dest);
				}
				else if (frame is FrameInMem)
				{
					uint8[] bytes = {};
					frame.cache.save_to_bufferv(out bytes, "jpeg", null, null);
					frame_encoded = new Bytes.take(bytes);
				}

				var dest = arch.new_child(@"media/$(frame.get_name())", false);

				dest.write(frame_encoded.get_data());
				dest.close();
			}

			arch.close();
		}

		/* Import/Export */
		void import_video(string path)
		{
			pipeline.set_state(Gst.State.NULL);
			this.src.set("uri", "file://" + path);
			pipeline.set_state(Gst.State.PAUSED);
			this.new_source();
		}

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