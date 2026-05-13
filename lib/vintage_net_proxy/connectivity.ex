defmodule VintageNetProxy.Connectivity do
  @moduledoc """
  Outbound-traffic connectivity checker.

  VintageNet's per-interface `connection` property tells you whether
  the interface itself has direct internet reachability — it can reach
  the outside without help. On corporate networks that resolve a proxy
  via WPAD/PAC, that signal is the wrong one to gate application
  behavior on: the interface is healthy and "internet"-classified, but
  outbound HTTP only works *through the proxy*, because direct egress
  is firewalled.

  This module reports the second signal. It periodically probes whether
  the proxy this library has resolved is actually able to carry outbound
  traffic, and publishes the result to the property table so other parts
  of the system can subscribe and react.

  ## Property

  The current connectivity state is published at
  `["proxy", "connectivity"]` in the `VintageNet` property table:

    * `:unknown` — no probe has run yet
    * `:ok` — the most recent probe succeeded
    * `{:error, reason}` — the most recent probe failed

  Subscribe to changes:

      VintageNetProxy.subscribe_connectivity()

      def handle_info({VintageNet, ["proxy", "connectivity"], _old, status, _}, s) do
        case status do
          :ok -> {:noreply, mark_online(s)}
          {:error, _} -> {:noreply, mark_offline(s)}
          :unknown -> {:noreply, s}
        end
      end

  ## Configuration

  Enable the checker by adding a `:connectivity` keyword list to the
  library's app environment:

      config :vintage_net_proxy,
        connectivity: [
          probe_urls: [
            "https://connectivitycheck.gstatic.com/generate_204",
            "https://detectportal.firefox.com/success.txt",
            "https://www.msftncsi.com/ncsi.txt"
          ],
          interval: 60_000
        ]

  `probe_urls` is a list, tried in order. The first one that succeeds
  wins — under normal operation only the first URL is probed, so a
  multi-URL list doesn't add traffic. The fallbacks only fire when an
  earlier probe target is itself broken (vendor outage, per-host
  filtering on the proxy), keeping a transient probe-target failure
  from being read as "the proxy is down."

  All keys are optional. The initial probe is delayed by
  `:initial_delay` (default 1 second) so the supervision tree has time
  to settle before the first network attempt.

  Set `connectivity: false` (or omit it) to leave the checker off — in
  that case this module is not started and the library behaves exactly
  as before.

  ## Isolation

  The checker is a single GenServer mounted at the Application level as
  a *sibling* of the main supervision tree. A crash here does not
  perturb the Selector, Interface processes, or the published proxy
  value, and vice versa. The only coupling is read-side: the checker
  subscribes to `["proxy", "config"]` and `["proxy", "pac_revision"]`
  to re-probe when the resolved proxy flips or its PAC reloads
  in-place, and calls `VintageNetProxy.resolve/1` when the published
  value is `:auto`. It writes only `["proxy", "connectivity"]`.

  ## Re-probe triggers

    1. Startup (after `:initial_delay`).
    2. Every `:interval` ms.
    3. `["proxy", "config"]` changes — different proxy model.
    4. `["proxy", "pac_revision"]` ticks — same PAC URL, new script
       body. The `config` property can't distinguish this case
       (both states publish `:auto`), so the Selector emits a separate
       tick on in-place reloads.
  """
  use GenServer

  alias VintageNetProxy.Connectivity.Probe
  alias VintageNetProxy.Publisher

  @property ["proxy", "connectivity"]
  @default_probe_urls [
    "https://connectivitycheck.gstatic.com/generate_204",
    "https://detectportal.firefox.com/success.txt",
    "https://www.msftncsi.com/ncsi.txt"
  ]
  @default_interval 60_000
  @default_initial_delay 1_000

  defstruct probe_urls: [],
            interval: nil,
            status: :unknown,
            timer: nil

  @type status :: :unknown | :ok | {:error, term()}

  # --- Client API ---

  @doc "Property table key under which connectivity state is published."
  @spec property() :: [String.t()]
  def property, do: @property

  @doc "Current connectivity state."
  @spec get() :: status()
  def get, do: VintageNet.get(@property, :unknown)

  @doc "Subscribe to connectivity state changes."
  @spec subscribe() :: :ok
  def subscribe, do: VintageNet.subscribe(@property)

  @doc "Unsubscribe from connectivity state changes."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: VintageNet.unsubscribe(@property)

  @doc """
  Run a probe right now and return its result. Also reschedules the
  periodic timer so the next automatic probe is one `:interval` away
  from now. Returns `:unknown` if the checker isn't running.
  """
  @spec check_now() :: status()
  def check_now do
    case Process.whereis(__MODULE__) do
      nil -> :unknown
      _pid -> GenServer.call(__MODULE__, :probe_now, 30_000)
    end
  end

  @doc """
  Introspection snapshot — the current status, configured probe URLs,
  and interval.
  """
  @spec status() :: %{
          status: status(),
          probe_urls: [String.t()],
          interval: pos_integer() | nil
        }
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{status: :unknown, probe_urls: [], interval: nil}
      _pid -> GenServer.call(__MODULE__, :status)
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    probe_urls = Keyword.get(opts, :probe_urls, @default_probe_urls)
    interval = Keyword.get(opts, :interval, @default_interval)
    initial_delay = Keyword.get(opts, :initial_delay, @default_initial_delay)

    publish(:unknown)
    VintageNet.subscribe(Publisher.property())
    VintageNet.subscribe(Publisher.pac_revision_property())

    state = %__MODULE__{
      probe_urls: probe_urls,
      interval: interval,
      timer: arm(initial_delay)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:probe_now, _from, state) do
    cancel(state.timer)
    state = probe(state)
    {:reply, state.status, %{state | timer: arm(state.interval)}}
  end

  def handle_call(:status, _from, state) do
    snap = %{status: state.status, probe_urls: state.probe_urls, interval: state.interval}
    {:reply, snap, state}
  end

  @impl true
  def handle_info(:probe, state) do
    state = probe(%{state | timer: nil})
    {:noreply, %{state | timer: arm(state.interval)}}
  end

  def handle_info({VintageNet, ["proxy", "config"], _old, _new, _meta}, state) do
    cancel(state.timer)
    {:noreply, %{state | timer: arm(0)}}
  end

  # In-place PAC reload (same effective URL, new body): the `config`
  # property stayed `:auto` so the previous clause never fires, but the
  # rules for what flows through the proxy may have changed. Probe again.
  def handle_info({VintageNet, ["proxy", "pac_revision"], _old, _new, _meta}, state) do
    cancel(state.timer)
    {:noreply, %{state | timer: arm(0)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp probe(state) do
    set_status(state, run_probes(state.probe_urls))
  end

  # Try each URL in order, halt on the first `:ok`. If all fail, return
  # the most recent error so logs include a concrete failure reason.
  defp run_probes([]), do: {:error, :no_probe_urls_configured}

  defp run_probes(urls) do
    Enum.reduce_while(urls, {:error, :no_probes_attempted}, fn url, _last ->
      case Probe.run(url, decide(url)) do
        :ok -> {:halt, :ok}
        {:error, _} = err -> {:cont, err}
      end
    end)
  end

  # Translate the published proxy model into a concrete decision Probe
  # can act on. `:auto` means "PAC is loaded; ask the Selector what the
  # proxy is for *this* URL"; everything else is already concrete.
  defp decide(probe_url) do
    case Publisher.get() do
      :unset -> :direct
      :direct -> :direct
      :auto -> VintageNetProxy.resolve(probe_url)
      %{} = descriptor -> descriptor
      _ -> :direct
    end
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    publish(status)
    %{state | status: status}
  end

  defp publish(status), do: PropertyTable.put(VintageNet, @property, status)

  defp arm(delay) when is_integer(delay) and delay >= 0,
    do: Process.send_after(self(), :probe, delay)

  defp cancel(nil), do: :ok

  defp cancel(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end
end
