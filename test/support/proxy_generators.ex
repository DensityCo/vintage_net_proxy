defmodule VintageNetProxy.TestGenerators do
  @moduledoc """
  StreamData generators shared across property test suites.

  Centralizes the proxy / intent shape generators so all PBT files
  agree on what "a random proxy state" or "a random intent config"
  means. Keep this module pure — no test-specific assertions, just
  generators.
  """

  import StreamData
  import ExUnitProperties, only: [gen: 1]

  alias VintageNetProxy.Interface.Proxy

  @up_states [:internet, :lan]
  @non_up_states [:disconnected, :lan_with_no_dns, nil, :internet_pending]
  @schemes [:http, :https, :socks4, :socks5]

  def up_states, do: @up_states
  def non_up_states, do: @non_up_states
  def schemes, do: @schemes

  def connection, do: member_of(@up_states ++ @non_up_states)

  def host, do: string(:alphanumeric, min_length: 1, max_length: 12)

  def port, do: integer(1..65_535)

  def pac_url do
    gen all(host <- host()) do
      "http://#{host}.example/wpad.dat"
    end
  end

  def pac_script, do: string(:printable, min_length: 1, max_length: 64)

  # --- Intent generators ---

  def intent do
    one_of([
      constant(nil),
      constant(%{mode: :direct}),
      auto_intent(),
      manual_intent()
    ])
  end

  def auto_intent do
    one_of([
      constant(%{mode: :auto}),
      gen all(url <- pac_url()) do
        %{mode: :auto, pac_url: url}
      end
    ])
  end

  def manual_intent do
    gen all(
          scheme <- member_of(@schemes),
          host <- host(),
          port <- port()
        ) do
      %{mode: :manual, scheme: scheme, host: host, port: port}
    end
  end

  # Manual intent with optional fields (credentials and/or bypass list).
  def manual_intent_with_optionals do
    gen all(
          base <- manual_intent(),
          creds <- one_of([constant(nil), credentials_pair()]),
          bypass <- one_of([constant(nil), list_of(host(), max_length: 3)])
        ) do
      base
      |> maybe_merge(creds)
      |> maybe_merge(if bypass, do: %{bypass: bypass}, else: nil)
    end
  end

  defp credentials_pair do
    gen all(
          u <- string(:alphanumeric, min_length: 1, max_length: 8),
          p <- string(:alphanumeric, min_length: 1, max_length: 8)
        ) do
      %{username: u, password: p}
    end
  end

  defp maybe_merge(map, nil), do: map
  defp maybe_merge(map, addition), do: Map.merge(map, addition)

  # --- Proxy generator ---

  def proxy(iface \\ "test0") do
    gen all(
          intent <- intent(),
          connection <- connection(),
          dhcp_wpad_url <- one_of([constant(nil), pac_url()]),
          dhcp_domain <- one_of([constant(nil), host()]),
          pac_script <- one_of([constant(nil), pac_script()])
        ) do
      %Proxy{
        iface: iface,
        intent: intent,
        connection: connection,
        dhcp_wpad_url: dhcp_wpad_url,
        dhcp_domain: dhcp_domain,
        pac_script: pac_script
      }
    end
  end
end
