// https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/tree/main/video/gtk4

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
	[GtkChild] Gtk.Image stage;
	[GtkChild] Gtk.ComboBoxText ana_mode_box;
	[GtkChild] Gtk.ToggleButton play_button;

	Gst.Pipeline pipeline;
	Gst.Element  anablend;
	Gst.Pad      delay_pad_l;
	Gst.Pad      delay_pad_r;

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
		this.pipeline = Gst.parse_launch("uridecodebin uri=file:///home/albert/Downloads/anaglyphs/mine/motion2.mp4 ! videoconvert ! videoscale ! video/x-raw,width=720,height=480 ! queue ! tee name=t ! queue name=queue_l ! anablend name=blend method=1 red_coef=1.1 ! videoconvert ! autovideosink sync=false name=sink t. ! queue name=queue_r ! blend.") as Gst.Pipeline;

		Gst.Element sync = this.pipeline.get_by_name("sync");
		this.anablend = this.pipeline.get_by_name("blend");
		this.delay_pad_l = this.pipeline.get_by_name("queue_l").sinkpads.first().data;
		this.delay_pad_r = this.pipeline.get_by_name("queue_r").sinkpads.first().data;
		
		pipeline.set_state(Gst.State.PAUSED);
		//  this.delay_pad_l.offset = (200*100000);

		/* Connect UI */

		this.anablend.bind_property("method", this.ana_mode_box, "active", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
	}

	/* UI callbacks */
	[GtkCallback]
	void on_open_file()
	{
		message("opened");
	}

	[GtkCallback]
	void on_play_clicked()
	{
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
	}

	[GtkCallback]
	void on_frame_difference_changed(Gtk.Adjustment adj)
	{
		//  pipeline.set_state(Gst.State.PAUSED);
		this.delay_pad_l.offset = (int64) ( double.max(0, adj.value) * 100000);
		this.delay_pad_r.offset = (int64) (-double.min(0, adj.value) * 100000);

		//  query = Gst.Query.new_position(Gst.Format.TIME)
		this.pipeline.get_by_name("sink").send_event(new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.ACCURATE | Gst.SeekFlags.FLUSH, Gst.SeekType.SET, 0, Gst.SeekType.NONE, 0));
		//  pipeline.set_state(Gst.State.PLAYING);
	}
}
