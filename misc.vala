delegate void SignalListItemFactoryCallback(Gtk.SignalListItemFactory @this, Gtk.ListItem li);

Gtk.SignalListItemFactory new_signal_list_item_factory(
    SignalListItemFactoryCallback? setup,
    SignalListItemFactoryCallback? teardown,
    SignalListItemFactoryCallback? bind,
    SignalListItemFactoryCallback? unbind
)
{
    var f = new Gtk.SignalListItemFactory();

    if (setup    != null) f.setup.connect((t, li) => setup(f, (Gtk.ListItem) li));      // FIXME: We get passed Objects, not ListItems so this cast might be ignoring some aspect of reaity
    if (teardown != null) f.teardown.connect((t, li) => teardown(f, (Gtk.ListItem) li));
    if (bind     != null) f.bind.connect((t, li) => bind(f, (Gtk.ListItem) li));
    if (unbind   != null) f.unbind.connect((t, li) => unbind(f, (Gtk.ListItem) li));

    return f;
}

class GenericArrayWrapper<T> : GLib.ListModel, Object
{
	GenericArray<T> arr;

	public GenericArrayWrapper(GenericArray<T> arr)
	{
		this.arr = arr;
	}

	public Object? get_item (uint pos)
	{
		return pos < arr.length ? arr.get(pos) as Object : null;
	}

	public Type get_item_type ()
	{
		return typeof(T);
	}

	public uint get_n_items ()
	{
		return arr.length;
	}
}

private Gtk.ActionBar insert_footer(Gtk.FileChooserDialog diag)
{
	var box = diag.get_content_area();
	var ab = new Gtk.ActionBar();
	box.append(ab);
	return ab;
}