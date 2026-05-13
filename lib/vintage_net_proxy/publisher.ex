defmodule VintageNetProxy.Publisher do
  @moduledoc """
  Owns the PropertyTable keys this library writes:

    * `["proxy", "config"]` — the resolved proxy model
      (`:unset | :direct | :auto | proxy_descriptor`).
    * `["proxy", "pac_revision"]` — a monotonic tick that fires when
      the active interface's PAC script content changes *in place*
      (same effective URL, new body). This is an internal signal used
      by `VintageNetProxy.Connectivity` to re-probe; the value carries
      no meaning beyond "something changed." Not part of the
      consumer-facing contract.

  Selector is the only writer.
  """

  @property ["proxy", "config"]
  @pac_revision_property ["proxy", "pac_revision"]

  @doc "Path of the published proxy config in the VintageNet PropertyTable."
  def property, do: @property

  @doc "Publish `value` to the proxy config key."
  def put(value), do: PropertyTable.put(VintageNet, @property, value)

  @doc "Read the currently published proxy config (`:unset` if nothing has been put)."
  def get, do: VintageNet.get(@property, :unset)

  @doc "Path of the PAC-revision tick property."
  def pac_revision_property, do: @pac_revision_property

  @doc """
  Publish a fresh PAC-revision value. Fires a change event on the
  `pac_revision` property so subscribers can react to in-place PAC
  reloads that don't move the `config` property.
  """
  def bump_pac_revision do
    PropertyTable.put(VintageNet, @pac_revision_property, System.monotonic_time())
  end
end
