defmodule VintageNetProxy.Persistence do
  @moduledoc """
  Behaviour for persisting VintageNetProxy state across reboots.

  The default implementation is `VintageNetProxy.Persistence.FlatFile`,
  which writes an Erlang term to disk. Override via app env:

      config :vintage_net_proxy, persistence: MyApp.MemoryPersistence
  """

  @type state :: %{
          optional(:target_url) => String.t(),
          optional(:wpad_url) => String.t(),
          optional(:override) => :direct | VintageNetProxy.proxy_descriptor()
        }

  @callback save(state) :: :ok | {:error, term()}
  @callback load() :: {:ok, state} | {:error, term()}
  @callback clear() :: :ok | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:vintage_net_proxy, :persistence, VintageNetProxy.Persistence.FlatFile)

  @spec save(state) :: :ok | {:error, term()}
  def save(state), do: impl().save(state)

  @spec load() :: {:ok, state} | {:error, term()}
  def load, do: impl().load()

  @spec clear() :: :ok | {:error, term()}
  def clear, do: impl().clear()
end
