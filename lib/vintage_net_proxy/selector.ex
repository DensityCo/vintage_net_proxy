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
    new_roster = Roster.put_iface(roster, iface, state)
    Publisher.put(Roster.value(new_roster))
    {:noreply, new_roster}
  end

  def handle_info(_msg, roster), do: {:noreply, roster}
end
