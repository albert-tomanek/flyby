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

private Gtk.ActionBar insert_footer(Gtk.Dialog diag)
{
	var box = diag.get_content_area();
	var ab = new Gtk.ActionBar();
	box.append(ab);
	return ab;
}


errordomain StateMachineError
{
	INVALID_TRANSITION
}

class StateMachine : Object
{
	public int state { get; private set; }

	private EnumClass states;
	private int[] valid_transitions = new int[0];	// Stores pairs


	public StateMachine(Type states_enum, int initial)
	requires(states_enum.is_enum())
	{
		this.state = initial;
		this.states = (EnumClass) states_enum.class_ref();
	}

	public StateMachine.with_edges(Type states_enum, int initial, unowned int[] edges)
	requires(states_enum.is_enum())
	{
		this.state = initial;
		this.states = (EnumClass) states_enum.class_ref();

		for (int i = 0; i < edges.length; i += 2)
			this.add_edge(edges[i], edges[i+1]);
	}

	public StateMachine.with_edges_bidi(Type states_enum, int initial, unowned int[] edges)
	requires(states_enum.is_enum())
	{
		this.state = initial;
		this.states = (EnumClass) states_enum.class_ref();

		for (int i = 0; i < edges.length; i += 2)
		{
			this.add_edge(edges[i], edges[i+1]);
			this.add_edge(edges[i+1], edges[i]);
		}
	}

	public void add_edge(int state_from, int state_to)
	{
		this.valid_transitions += state_from;
		this.valid_transitions += state_to;
	}

	internal signal void transitioned(int from, int to, ref bool rc_accum);

	public bool change_state(int new_state) throws StateMachineError
	{
		if (state_change_valid(this.state, new_state))
		{
			var old_state = this.state;
			this.state = new_state;

			bool success = true;
			transitioned(old_state, this.state, ref success);

			if (!success)
				this.state = old_state;

			return success;
		}
		else
			throw new StateMachineError.INVALID_TRANSITION(@"Can't change `$(states.get_type().name())` directly from `$(EnumClass.to_string(this.states.get_type(), this.state))` to `$(EnumClass.to_string(this.states.get_type(), new_state))`.");
	}

	public bool state_change_valid(int from, int to)
	{
		if (from == to) return true;

		for (int i = 0; i < this.valid_transitions.length; i += 2)
			if (this.valid_transitions[i] == from && this.valid_transitions[i + 1] == to)
				return true;
		
		return false;
	}

	public bool orthogonal_to(int to_state)
	{
		return this.state_change_valid(this.state, to_state);
	}


	public ulong on_enter(int to_state, SourceFunc cb)
	{
		return this.transitioned.connect((from, to, ref rc) => {
			if (to == to_state)
				rc = rc && cb();
		});
	}

	public ulong on_leave(int from_state, SourceFunc cb)
	{
		return this.transitioned.connect((from, to, ref rc) => {
			if (from == from_state)
				rc = rc && cb();
		});
	}

	public ulong on_transition(int from_state, int to_state, SourceFunc cb)
	{
		return this.transitioned.connect_after((from, to, ref rc) => {  // TODO: Use a GSignalAccumulator instead of `ref rc`
			if (from == from_state && to == to_state)
				rc = rc && cb();
		});
	}
}