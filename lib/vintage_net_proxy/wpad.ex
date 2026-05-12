defmodule VintageNetProxy.Wpad do
  @moduledoc """
  Web Proxy Auto-Discovery helpers.

  Currently provides one thing: constructing the conventional
  `http://wpad.<domain>/wpad.dat` URL from a DNS domain. Used as the
  third-tier fallback in `VintageNetProxy.Interface.effective_pac_url/1`
  after an explicit `:pac_url` and after a DHCP option 252 `:wpad` URL.

  This is the fallback path that lets corporate networks publish a PAC
  script via DNS only — no DHCP option 252 required — by simply
  resolving `wpad.<their-domain>` to a host that serves
  `/wpad.dat`. Many real-world networks rely on this fallback.

  ## Security note

  Some implementations walk up the DNS hierarchy
  (`wpad.eng.corp.example.com` → `wpad.corp.example.com` → ...) until
  a server responds. That's the source of historical WPAD spoofing
  attacks where a server in a parent domain hijacks proxy settings for
  all sub-domains. **This module does NOT walk up the hierarchy.** It
  constructs exactly one URL from the exact domain handed to it. To
  try multiple domains, the caller must invoke `dns_url/1` for each.
  """

  @doc """
  Build `http://wpad.<domain>/wpad.dat` from a DNS domain, or `nil` if
  the domain is empty, malformed, or otherwise unsafe to construct a URL
  from.

  Accepts a leading dot (`.corp.example.com`) — the dot is stripped —
  so a domain pulled straight out of DHCP option 119 (search list) can
  be passed in directly.
  """
  @spec dns_url(String.t() | nil) :: String.t() | nil
  def dns_url(nil), do: nil
  def dns_url(""), do: nil

  def dns_url(domain) when is_binary(domain) do
    domain = domain |> String.trim() |> String.trim_leading(".") |> String.trim_trailing(".")

    if valid_domain?(domain) do
      "http://wpad.#{domain}/wpad.dat"
    else
      nil
    end
  end

  def dns_url(_), do: nil

  # Loose check: alphanumerics, dots, hyphens; non-empty after trimming.
  # We don't enforce RFC 1035 hostname rules strictly — the network gets
  # to pick its own domain shape — but we do reject anything containing
  # path characters, whitespace, or scheme separators that would let a
  # malicious DHCP server inject arbitrary URLs.
  defp valid_domain?(""), do: false

  defp valid_domain?(domain) do
    Regex.match?(~r/^[A-Za-z0-9.-]+$/, domain)
  end
end
