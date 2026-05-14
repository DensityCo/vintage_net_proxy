defmodule VintageNetProxy.Addresses do
  @moduledoc """
  Parse VintageNet's `addresses` property into the shape PAC needs.

  VintageNet exposes addresses as a list of maps like
  `%{family: :inet, address: {10, 1, 2, 3}, ...}`. PAC scripts that
  call `myIpAddress()` (typically inside `isInNet(myIpAddress(), …)`
  for subnet-aware routing) expect a dotted-quad string. This module
  bridges the two.
  """

  @doc """
  First IPv4 address from VintageNet's `addresses` list, formatted as
  `"a.b.c.d"`, or `nil` if none is present (interface down, IPv6-only
  lease, non-list input, etc.).

  When the result is `nil`, PAC's `myIpAddress()` evaluates to "no IP"
  and the surrounding `isInNet` falls through.
  """
  @spec first_ipv4(term()) :: String.t() | nil
  def first_ipv4(addresses) when is_list(addresses) do
    Enum.find_value(addresses, fn
      %{family: :inet, address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end)
  end

  def first_ipv4(_), do: nil
end
