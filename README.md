# vintage_net_proxy

Resolve a system HTTP proxy from DHCP Option 252 (WPAD) or manual configuration,
and expose the result via the [VintageNet](https://hex.pm/packages/vintage_net)
property table.

Designed to replace polling + file-based IPC + service-restart architectures
(PACrunner, D-Bus, etc.) with event-driven property subscriptions.

## Property surface

The current proxy is published at `["proxy", "config"]` in the `VintageNet`
property table as one of:

| Value | Meaning |
|---|---|
| `:unset` | No proxy info available yet (no PAC fetched, no manual override) |
| `:direct` | Bypass any proxy; connect directly |
| `proxy_descriptor` | A map describing a proxy to use |

The `proxy_descriptor` map looks like:

```elixir
%{
  scheme: :http,         # :http | :https | :socks4 | :socks5
  host: "proxy.corp",
  port: 8080,
  username: "alice",     # optional
  password: "secret"     # optional
}
```

`:scheme`, `:host`, `:port` are always present. `:username` / `:password`
are present only for authenticated proxies (typically set via
`set_manual/1`; the bundled PAC parser does not extract credentials).

## Consumer pattern

```elixir
VintageNet.subscribe(["interface", "wlan0", "connection"])
VintageNet.subscribe(VintageNetProxy.property())

def handle_info({VintageNet, ["interface", _, "connection"], _, :internet, _}, state) do
  {:noreply, connect_upstream(state, VintageNetProxy.get())}
end

def handle_info({VintageNet, ["proxy", "config"], _, proxy, _}, state) do
  case proxy do
    :unset -> {:noreply, state}                 # wait or skip
    :direct -> {:noreply, connect_direct(state)}
    %{scheme: :http} = px -> {:noreply, connect_http(state, px)}
    %{scheme: :https} = px -> {:noreply, connect_https(state, px)}
    %{scheme: scheme} = px when scheme in [:socks4, :socks5] ->
      {:noreply, connect_socks(state, px)}
  end
end
```

## Runtime configuration

Everything is settable at runtime. There's no compile-time `config` to wire up.

### Target URL (PAC evaluation context)

```elixir
VintageNetProxy.set_target_url("https://api.example.com/")
VintageNetProxy.get_target_url()
```

When a PAC script is loaded, it's evaluated against this URL and the
result is published. Set this to the upstream the device cares about —
typically the cloud API endpoint. If unset, PAC evaluates against
`"http://localhost/"`, which falls through to the script's default branch.

### WPAD URL (PAC source)

```elixir
VintageNetProxy.set_wpad_url("http://wpad.corp.example/wpad.dat")
VintageNetProxy.clear_wpad_url()
```

Setting this triggers a PAC fetch + re-publish. Equivalent to writing
`["interface", iface, "wpad_url"]` directly to the property table — use
whichever fits (e.g., a udhcpc hook would write the property; a BLE
provisioning flow might call `set_wpad_url/1`).

### Manual override

For BLE-provisioned proxies or other out-of-band configuration:

```elixir
# Simple HTTP (most common)
VintageNetProxy.set_manual("proxy.corp.example", 8080)

# Full descriptor — non-HTTP schemes or authenticated proxies
VintageNetProxy.set_manual(%{
  scheme: :socks5,
  host: "socks.corp.example",
  port: 1080,
  username: "alice",
  password: "secret"
})

VintageNetProxy.set_direct()
VintageNetProxy.clear()
```

Manual overrides take precedence over PAC. `clear/0` reverts to whatever
WPAD provides.

## Per-URL resolution (advanced)

If you have a generic HTTP client that needs per-URL routing, use
`resolve/1` instead of subscribing:

```elixir
VintageNetProxy.resolve("https://api.example.com/")
#=> %{scheme: :http, host: "corp-proxy", port: 8080}

VintageNetProxy.resolve("http://intranet/")
#=> :direct
```

Most embedded devices talk to a known set of upstreams and can use the
property-subscription pattern instead.

## Persistence

Runtime state survives reboots. The default
`VintageNetProxy.Persistence.FlatFile` impl writes an Erlang term to
`/root/vintage_net_proxy/state` (configurable; mirrors `VintageNet`'s own
persistence layout).

Persisted fields:

- `target_url` — set via `set_target_url/1`
- `wpad_url` — set via `set_wpad_url/1`, or external writes to
  `["interface", iface, "wpad_url"]` (e.g., a udhcpc hook)
- `override` — set via `set_manual/2`, `set_direct/0`

The PAC script itself is *not* persisted — it's refetched on boot from the
restored `wpad_url`. (PAC scripts can change server-side; refreshing is
the right semantic.)

### Loading happens synchronously in `init/1`

The Server's `init/1` loads persistence before returning, so by the time
`Application.started?(:vintage_net_proxy)` is true, the property
`["proxy", "config"]` already reflects any persisted manual override.
This closes the boot-timing window where a consumer might see
`connection: :internet` before the proxy state has been restored.

### Configuration

```elixir
# config/config.exs (or release.exs)
config :vintage_net_proxy,
  persistence: VintageNetProxy.Persistence.FlatFile,
  persistence_dir: "/root/vintage_net_proxy"
```

For tests:

```elixir
# config/test.exs
config :vintage_net_proxy, persistence: VintageNetProxy.Persistence.Null
```

### Custom backend

Implement the `VintageNetProxy.Persistence` behaviour (`save/1`, `load/0`,
`clear/0`) and point `:persistence` at your module.

## DHCP Option 252 wiring

The server subscribes to `["interface", iface, "wpad_url"]` (interface
defaults to `"wlan0"`). Anything that writes to that property triggers a
PAC fetch — typically a small udhcpc hook on lease renewal:

```elixir
PropertyTable.put(VintageNet, ["interface", "wlan0", "wpad_url"], url)
```

Or use the equivalent `VintageNetProxy.set_wpad_url/1` API if you're
calling from inside the BEAM. On lease renewal or interface up, the
library re-fetches the PAC script automatically (subscribes to
`["interface", iface, "lower_up"]` too).

## PAC subset

The bundled PAC evaluator handles the patterns found in typical corporate
WPAD scripts.

**Predicates:**
- `shExpMatch(host, "<glob>")` — `*` and `?` wildcards
- `dnsDomainIs(host, ".<suffix>")` — case-insensitive suffix match
- `isPlainHostName(host)`
- `host == "<literal>"` / `host === "<literal>"`

**Directives:**
- `"DIRECT"` → `:direct`
- `"PROXY host:port"` → `%{scheme: :http, ...}`
- `"HTTPS host:port"` → `%{scheme: :https, ...}`
- `"SOCKS host:port"` / `"SOCKS4 host:port"` → `%{scheme: :socks4, ...}`
- `"SOCKS5 host:port"` → `%{scheme: :socks5, ...}`
- Fallback lists (`"PROXY a:1; PROXY b:2; DIRECT"`) — only the first
  recognized entry is returned

Anything outside this subset is treated as an unmatched predicate and falls
through to the next rule. Malformed scripts return `:direct`.

If real-world PAC files need more (logical operators, `isInNet`,
`myIpAddress`, credential parsing, etc.), extend `VintageNetProxy.PAC`.

## Why no Duktape / PACrunner

A full JavaScript engine is the correct general solution but a poor fit
for embedded Nerves devices: ~1MB of binary, a C dependency, and a
sandbox we'd have to reason about for security. The simple subset
evaluator fits in ~150 lines of Elixir and covers the cases real
corporate networks actually deploy. Revisit if a customer ships a PAC
file that needs the full grammar.

## Status

Early. No production deployments yet. The PAC parser is deliberately
small; real-world PAC files may exercise predicates this library doesn't
handle. File issues with the offending script attached.
