// https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/tree/main/video/gtk4
// https://packages.debian.org/sid/gstreamer1.0-gtk4

public class FlyByApp : Gtk.Application {
	public FlyByApp () {
		Object(
			application_id: "com.github.albert-tomanek.flyby",
			flags: ApplicationFlags.FLAGS_NONE
		);
	}

	protected override void activate () {
		var win = new FlyBy(this);
		win.show ();

		this.add_window(win);
		win.show();
	}

	public static int main(string[] args)
	{
		Gst.init(ref args);

		var app = new FlyByApp();
		return app.run(args);
	}
}

[GtkTemplate (ui = "/com/github/albert-tomanek/flyby/main.ui")]
class FlyBy : Gtk.ApplicationWindow
{
	[GtkChild] Gtk.Box stage;
	[GtkChild] Gtk.ComboBoxText ana_mode_box;
	[GtkChild] Gtk.ToggleButton play_button;
	[GtkChild] Gtk.Adjustment   framediff_adj;
	[GtkChild] Gtk.Scale        framediff_scale;
	[GtkChild] Gtk.Scale        position_scale;
	[GtkChild] Gtk.Adjustment   position_adj;
	[GtkChild] Gtk.Adjustment   redboost_adj;
	[GtkChild] Gtk.Button       export_button;
	[GtkChild] Gtk.Dialog       export_dialog;
	[GtkChild] Gtk.ProgressBar  export_progressbar;

	Gst.Pipeline pipeline;
	Gst.Bin      export_bin;
	Gst.Element  export_tee;
	Gst.Pad?     export_tee_pad = null;
	Gst.Element  src;
	Gst.Element  sink;
	Gst.Element  anablend;
	Gst.Pad      delay_pad_l;
	Gst.Pad      delay_pad_r;

	Gst.ClockTime duration { get; set; }
	Gst.ClockTime position {
		get {
			Gst.ClockTime pos;
			this.pipeline.query_position(Gst.Format.PERCENT, out pos);
			return pos;
		}
	}

	signal void export_start(string path);
	signal void export_finished();
	signal void new_source();

	public FlyBy(Gtk.Application app)
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

		/* Application states */
		this.export_start.connect((path) => {
			pipeline.set_state(Gst.State.PAUSED);
			this.export_bin.get_by_name("filesink").set("location", path);
			this.add_export_branch();
			this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, 0, Gst.SeekType.NONE, 0));
			pipeline.set_state(Gst.State.PLAYING);
		});
		this.export_finished.connect(this.remove_export_branch);

		/* Duration & progress */
		this.new_source.connect(() => {
			unowned string? uri;
			this.src.get("uri", out uri);
			var info = (new Gst.PbUtils.Discoverer(1 * Gst.SECOND)).discover_uri(uri);
			this.duration = info.get_duration();

			//  int64 _duration;
			//  var rc = this.pipeline.query_duration(Gst.Format.TIME, out _duration);
			//  this.duration = _duration;
			message(@"queried duraiton, $duration");
		});
		this.position_scale.change_value.connect((type, set_to) => {
			int64 time = (int64) (set_to * 1000000);
			message(@"seek $time");
			this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.PERCENT, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, time, Gst.SeekType.NONE, 0));
		});
		//  Timeout.add(1000/60, () => {
		//  	this.position_adj.value = ((double) this.position) / 1000000;
		//  	message(@"$(this.position_adj.value) = $position / $duration");
		//  	return Source.CONTINUE;
		//  });
		this.sink.get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER, (pad, info) => {
			var buf = info.get_buffer();

			if (buf != null)
			{
				this.position_adj.value = (double) buf.pts / this.duration;
			}
			return Gst.PadProbeReturn.PASS;
		});
		
		/* Connect UI */
		
		this.anablend.bind_property("method", this.ana_mode_box, "active", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
		this.redboost_adj.bind_property("value", this.anablend, "red_coef", BindingFlags.SYNC_CREATE);
		this.src.bind_property("uri", this.export_button, "sensitive", BindingFlags.SYNC_CREATE, (b, from, ref to) => { to.set_boolean(from.get_string() != null); return true; });
		// Play button
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
		//  this.sink.get_static_pad("sink").add_probe(Gst.PadProbeType.EVENT_DOWNSTREAM, (pad, info) => {
		//  	var event = info.get_event();

		//  	if (event != null)
		//  	{
		//  		if (event.type == Gst.EventType.EOS)
		//  		{
		//  			message("seeking %b", this.export_branch_connected);
		//  			if (this.export_branch_connected)
		//  				this.remove_export_branch();
		//  			this.pipeline.get_by_name("src").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH, Gst.SeekType.SET, 0, Gst.SeekType.NONE, 0));
		//  			return Gst.PadProbeReturn.PASS;
		//  		}
		//  	}
		//  	return Gst.PadProbeReturn.PASS;
		//  });
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

			message(@"$new_state", new_state);
			this.play_button.active = (new_state == Gst.State.PLAYING);
		});
		this.on_frame_difference_changed();

		// Modal dialogs
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
			{
				pipeline.set_state(Gst.State.NULL);
				this.src.set("uri", "file://" + d.get_file().get_path());
				pipeline.set_state(Gst.State.PAUSED);
				this.new_source();
			}

			d.close();
		});
		//  this.reset_adjustment();
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

		/* I know it's stupid, but we get the current playback time and seek to it (in order to flush). */
		var query = new Gst.Query.position(Gst.Format.TIME);
		if (pipeline.query(query))
		{
			int64 time;
			query.parse_position(null, out time);
			this.pipeline.get_by_name("sink").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.ACCURATE | Gst.SeekFlags.FLUSH, Gst.SeekType.SET, time, Gst.SeekType.NONE, 0));
		}
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
}
