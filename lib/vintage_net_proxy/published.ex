defmodule VintageNetProxy.Published do
  @moduledoc false

  # The single public PropertyTable key this library writes.
  @property ["proxy", "config"]

  @doc "Path of the published proxy config in the VintageNet PropertyTable."
  def property, do: @property

  @doc "Publish `value` to the proxy config key."
  def put(value), do: PropertyTable.put(VintageNet, @property, value)

  @doc "Read the currently published proxy config (`:unset` if nothing has been put)."
  def get, do: VintageNet.get(@property, :unset)
end
