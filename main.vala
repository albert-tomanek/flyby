
public class FlyByApp : Gtk.Application {
	public FlyByApp () {
		Object(application_id: "com.github.albert-tomanek.flyby",
				flags: ApplicationFlags.FLAGS_NONE);
	}

	protected override void activate () {
		var win = new FlyBy(this);
		win.show ();

		this.add_window(win);
		win.show();
	}

	public static int main(string[] args)
	{
		var app = new FlyByApp();
		return app.run(args);
	}
}

[GtkTemplate (ui = "/com/github/albert-tomanek/flyby/main.ui")]
class FlyBy : Gtk.ApplicationWindow
{
	[GtkChild]
	Gtk.Label label;

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
}
