defmodule VintageNetProxy.Selector do
  @moduledoc """
  Snapshot aggregator GenServer.

  Receives `{:interface_changed, iface, state}` messages from each
  `VintageNetProxy.Interface` process, keeps the latest snapshot per
  interface in a `VintageNetProxy.Roster`, picks the highest-priority
  eligible interface, and publishes the resulting proxy value via
  `VintageNetProxy.Publisher`. Serves `resolve/1` and `status/0` from
  the cached snapshots so neither call ever blocks on an in-flight
  PAC fetch.
  """
  use GenServer

  alias VintageNetProxy.{Publisher, Roster}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []
    roster = Roster.new(interfaces, %{})
    Publisher.put(Roster.value(roster))
    {:ok, roster}
  end

  @impl true
  def handle_call(:status, _from, roster),
    do: {:reply, Roster.status(roster, Publisher.get()), roster}

  def handle_call({:resolve, url}, _from, roster),
    do: {:reply, Roster.resolve(roster, url), roster}

  @impl true
  def handle_info({:interface_changed, iface, state}, roster) do
    old_state = Roster.get_iface(roster, iface)
    new_roster = Roster.put_iface(roster, iface, state)
    Publisher.put(Roster.value(new_roster))
    if pac_reloaded_in_place?(old_state, state), do: Publisher.bump_pac_revision()
    {:noreply, new_roster}
  end

  def handle_info(_msg, roster), do: {:noreply, roster}

  # Fires only when the PAC script content changes from one non-nil
  # value to a different non-nil value — the narrow case the
  # `config` property can't distinguish (both states publish `:auto`).
  # nil → non-nil and non-nil → nil transitions show up via the
  # `config` property going `:unset` ↔ `:auto`, so we deliberately
  # don't fire here for those.
  defp pac_reloaded_in_place?(%{pac_script: old}, %{pac_script: new})
       when is_binary(old) and is_binary(new) and old != new,
       do: true

  defp pac_reloaded_in_place?(_, _), do: false
end
