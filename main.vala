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
				flags: ApplicationFlags.HANDLES_OPEN
			);
		}

		protected override void activate () {
			var win = new FlyBy.MainWindow(this);
			this.add_window(win);
			win.show();
		}

		protected override void open (File[] files, string hint) {
			foreach (var file in files)
			{
				var win = new FlyBy.MainWindow(this);
				this.add_window(win);
				win.show();

				win.open.begin(file, (_, ctx) => {
					win.open.end(ctx);
				});
			}
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

		public bool hidden  { get; set; default = false; }
		public double offset_x { get; set; default = 0; }	// as percentage of width
		public double offset_y { get; set; default = 0; }	// as percentage of height

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

	class Stage : Gtk.DrawingArea
	{
		public AnaglyphMethod method { get; set; }
		public double red_coef { get; set; }

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

			this.notify["frame-l"].connect(() => {
				// Stop listening to changes in the old frame.
				if (old_frame_l != null)
					old_frame_l.disconnect(frame_l_notify_binding);

				// Loading is async so we actually have to wait until the property appears
				frame_l_notify_binding = frame_l.notify.connect(() => {
					this.refresh_pixbuf();
					this.queue_draw();
				});
				// We just got a new frame_l and that means also a new frame_l.cache. Trigger a redraw.
				frame_l.notify_property("cache");
				
				old_frame_l = frame_l;
			});
			this.notify["frame-r"].connect(() => {
				if (old_frame_r != null)
					old_frame_r.disconnect(frame_r_notify_binding);

				if (frame_r != null)
				{
					frame_r_notify_binding = frame_r.notify.connect(() => {
						this.refresh_pixbuf();
						this.queue_draw();
					});
					frame_r.notify_property("cache");
				}

				old_frame_r = frame_r;
			});
			this.notify["method"].connect(() => {
				this.refresh_pixbuf();
				this.queue_draw();
			});
			this.notify["red-coef"].connect(() => {
				this.refresh_pixbuf();
				this.queue_draw();
			});

			this.set_draw_func((_, cr, w, h) => { this.draw(cr); });
			this.resize.connect(() => { this.refresh_pixbuf(); });

			// UI stuff

			// Drag
			var drag = new Gtk.GestureDrag() {
				button = Gdk.BUTTON_PRIMARY,
			};
			this.add_controller(drag);

			double old_offset_x, old_offset_y;
			drag.drag_begin.connect(() => {
				old_offset_x = this.frame_l.offset_x;
				old_offset_y = this.frame_l.offset_y;
			});
			drag.drag_update.connect((dx, dy) => {
				var letterbox = this.get_letterbox();

				this.frame_l.offset_x = old_offset_x + (dx / letterbox.width);
				this.frame_l.offset_y = old_offset_y + (dy / letterbox.height);
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

		private Gdk.Rectangle get_letterbox()
		requires (this.frame_l.cache != null)
		{
			// Work out the size and position of the scaled image
			double src_aspect  = (double) this.frame_l.cache.width  / (double) this.frame_l.cache.height;
			double dest_aspect = (double) this.get_width() / (double) this.get_height();

			var letterbox = Gdk.Rectangle();

			if (src_aspect > dest_aspect) {
				letterbox.width  = this.get_width();
				letterbox.height = (int) (letterbox.width / src_aspect);
				letterbox.x = 0;
				letterbox.y = (this.get_height() - letterbox.height) / 2;
			} else {
				letterbox.height = this.get_height();
				letterbox.width  = (int) (letterbox.height * src_aspect);
				letterbox.x = (this.get_width() - letterbox.width) / 2;
				letterbox.y = 0;
			}

			return letterbox;
		}

		private void refresh_pixbuf()
		{
			if (this.frame_l != null)
			{
				var pixbuf_l = this.render_frame(this.frame_l);
				
				if (this.method == AnaglyphMethod.NONE || this.frame_r == null)
					this.pixbuf = pixbuf_l;
				else
				{
					var pixbuf_r = this.render_frame(this.frame_r);
					this.pixbuf  = make_anaglyph(pixbuf_l, pixbuf_r, this.method, (float) this.red_coef);
				}
			}
		}

		private Gdk.Pixbuf render_frame(Frame frame)
		{
			var render = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, this.get_width(), this.get_height());
			
			if (frame.cache != null)
			{
				var letterbox = this.get_letterbox();
				var scaled = frame.cache.scale_simple(letterbox.width, letterbox.height, Gdk.InterpType.NEAREST);

				// Copy the appropriate part of the image with regards to frame offset
				var position = Gdk.Rectangle() {
					x = letterbox.x + (int) (frame.offset_x * letterbox.width),
					y = letterbox.y + (int) (frame.offset_y * letterbox.height),
					width  = letterbox.width,
					height = letterbox.height,
				};

				Gtk.Allocation bounds;
				Gdk.Rectangle position_clipped;
				this.get_allocation(out bounds);
				bounds.intersect(position, out position_clipped);

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
	}

	[GtkTemplate (ui = "/com/github/albert-tomanek/flyby/main.ui")]
	class MainWindow : Gtk.ApplicationWindow
	{
		/* UI */
		[GtkChild] Gtk.Box          stage_box;
		           FlyBy.Stage      stage = new FlyBy.Stage();

		[GtkChild] Gtk.ColumnView   frame_listview;

		[GtkChild] Gtk.Box          media_bar;
		[GtkChild] Gtk.ToggleButton play_button;
		           int              play_state;		// -1 = advancing backward, 0 = not playing, 1 = advancing forward
		[GtkChild] Gtk.Scale        position_scale;
		[GtkChild] Gtk.Adjustment   position_adj;
		[GtkChild] Gtk.Adjustment   fps_adj;
		
		[GtkChild] Gtk.ComboBoxText ana_mode_box;
		[GtkChild] Gtk.Adjustment   redboost_adj;

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

			//
			var settings = new Settings ("com.github.albert-tomanek.flyby");
			settings.bind("red-boost", this.stage, "red-coef", SettingsBindFlags.DEFAULT);
		}

		void init_ui()
		{
			this.stage_box.append(this.stage);
			this.frames.bind_property("n-items", this.stage, "visible", BindingFlags.SYNC_CREATE, (_, src, ref dst) => {	// Only show the stage when a frame can be selected. This lets us avoid a null frame state in FlyBy.Stage code
				dst.set_boolean(src.get_uint() > 0); return true;
			});

			this.ana_mode_box.bind_property("active", this.stage, "method", BindingFlags.BIDIRECTIONAL);
			this.ana_mode_box.active = 1;

			this.redboost_adj.bind_property("value", this.stage, "red-coef", BindingFlags.BIDIRECTIONAL);

			{
				var keypress = new Gtk.EventControllerKey();
				keypress.key_pressed.connect((keyval, keycode, mod_state) => {
					if (keyval == Gdk.Key.n && (mod_state & Gdk.ModifierType.CONTROL_MASK) != 0)
					{
						this.application.activate();
					}
					return false;
				});
				(this as Gtk.Widget).add_controller(keypress);
			}

			/* Frame list */
			{
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
			}

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

		/* Load/Save */

		public async void open(File file)
		{
			this.title = @"FlyBy – $(file.get_basename())";

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
				this.fps_adj.value = cur.get_double_value();
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
				this.frames.append(frame);
			}
			cur.end_member();
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
				builder.add_double_value(this.fps_adj.value);

				builder.set_member_name ("frames");
				builder.begin_array ();
				for (uint i = 0; i < this.frames.get_n_items(); i++)
				{
					var frame  = this.frames.get_item(i) as Frame;

					builder.begin_object();
						builder.set_member_name("filename");
						builder.add_string_value(frame.get_name());

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
	}
}