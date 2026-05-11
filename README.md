# vintage_net_proxy

Resolve a system HTTP proxy from a per-interface `:proxy` configuration
field (optionally combined with DHCP Option 252 / WPAD discovery), and
expose the result via the
[VintageNet](https://hex.pm/packages/vintage_net) property table.

Designed to replace polling + file-based IPC + service-restart
architectures (PACrunner, D-Bus, etc.) with event-driven property
subscriptions.

## Property surface

The current proxy *model* is published at `["proxy", "config"]` in the
`VintageNet` property table as one of:

| Value | Meaning |
|---|---|
| `:unset` | No proxy intent, or PAC intent without a loaded script yet |
| `:direct` | Bypass any proxy; connect directly |
| `proxy_descriptor` | A fixed proxy to use for everything |
| `:auto` | PAC-managed — call `VintageNetProxy.resolve(url)` per request |

PAC is inherently per-URL, so for `:auto` the library does not compress
the script down to a single descriptor. The published value is the
sentinel `:auto`; consumers route each outbound URL through
`resolve/1` for a concrete answer.

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
are present only for authenticated proxies (typically set via the
`:manual` mode; the bundled PAC parser does not extract credentials).

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
    :auto -> {:noreply, state}                  # use resolve(url) per request
    %{scheme: :http} = px -> {:noreply, connect_http(state, px)}
    %{scheme: :https} = px -> {:noreply, connect_https(state, px)}
    %{scheme: scheme} = px when scheme in [:socks4, :socks5] ->
      {:noreply, connect_socks(state, px)}
  end
end
```

## Configuration

All proxy configuration is expressed as a `:proxy` field inside an
interface configuration. The schema follows GNOME's
`org.gnome.system.proxy` taxonomy (`:direct | :auto | :manual`), which is
the de facto Linux desktop convention.

See `VintageNetProxy.Config` for full schema details.

### Direct — bypass any proxy

```elixir
VintageNet.configure("eth0", %{
  type: VintageNetEthernet,
  ipv4: %{method: :dhcp},
  proxy: %{mode: :direct}
})
```

### Auto — PAC-based discovery

Use DHCP-supplied WPAD URL (Option 252):

```elixir
VintageNet.configure("wlan0", %{
  type: VintageNetWiFi,
  ipv4: %{method: :dhcp},
  proxy: %{mode: :auto}
})
```

Or pin an explicit PAC URL:

```elixir
VintageNet.configure("wlan0", %{
  type: VintageNetWiFi,
  ipv4: %{method: :dhcp},
  proxy: %{mode: :auto, pac_url: "http://wpad.corp/wpad.dat"}
})
```

### Manual — explicit proxy

```elixir
VintageNet.configure("wlan0", %{
  type: VintageNetWiFi,
  ipv4: %{method: :dhcp},
  proxy: %{
    mode: :manual,
    scheme: :http,            # defaults to :http if omitted
    host: "proxy.corp",
    port: 8080,
    username: "alice",        # optional
    password: "secret"        # optional
  }
})
```

`:scheme` accepts `:http`, `:https`, `:socks4`, or `:socks5`.

### Per-interface, per-network

Because intent lives in the interface configuration, each interface can
have its own proxy policy. A roaming device can have a corporate proxy
on `wlan0` and go direct on `eth0`:

```elixir
VintageNet.configure("wlan0", %{type: VintageNetWiFi, ipv4: %{method: :dhcp},
                                proxy: %{mode: :auto}})
VintageNet.configure("eth0",  %{type: VintageNetEthernet, ipv4: %{method: :dhcp},
                                proxy: %{mode: :direct}})
```

Tell the library which interfaces to track, in priority order:

```elixir
config :vintage_net_proxy, interfaces: ["eth0", "wlan0"]
```

At runtime the library walks the list and picks the first interface
that (a) is connected (`connection` is `:internet` or `:lan`) and
(b) has a `:proxy` intent in its config. When the active interface goes
offline, the next eligible one takes over; when it returns, it
reclaims. Each interface's PAC script is cached only while that
interface is up — disconnecting drops the script so a reconnect
re-fetches against the (possibly new) network.

### Architecture

```
VintageNetProxy.Supervisor
└── VintageNetProxy.Selector  (one GenServer)
```

The single `Selector` GenServer subscribes to each tracked interface's
`config`, `dhcp_options`, and `connection` PropertyTable keys, and
holds `%{iface => %Interface{}}` in its state. On each property event
it routes to the matching `Interface.on_config/2`,
`Interface.on_dhcp_options/2`, or `Interface.on_connection/2`,
updates that interface's struct, walks the priority list to pick the
first `eligible?` one, and publishes `Interface.value/1` to the
global `["proxy", "config"]`.

`VintageNetProxy.Interface` is a **pure data module** — a struct plus
state-transition functions (`on_*`, `eligible?`, `value`, `resolve`,
`snapshot`). It has no process of its own; the Selector owns the only
mailbox. The mode-to-value mapping (direct / manual descriptor /
`:auto` / `:unset`) lives in `Interface.value/1`, next to the state
that determines it.

`Selector.status/0` reads its own state synchronously — no fan-out
calls, no sync barrier needed. The single mailbox imposes a total
order on events and on publishes.

## Persistence

There is no separate persistence layer. VintageNet already persists
interface configurations (encrypted, with the same machinery that hides
WiFi passphrases), so the `:proxy` field gets persisted alongside the
rest of the interface config and is restored on boot automatically.

## Per-URL resolution

PAC scripts are a function from URL → proxy decision, so for `:auto`
mode the published property is the sentinel `:auto`, not a descriptor.
Consumers call `resolve/1` per request:

```elixir
VintageNetProxy.resolve("https://api.example.com/")
#=> %{scheme: :http, host: "corp-proxy", port: 8080}

VintageNetProxy.resolve("http://intranet/")
#=> :direct
```

For `:manual` and `:direct` modes the answer is the same regardless of
URL, so subscribing to `["proxy", "config"]` is enough. Embedded devices
that talk to a single known upstream can also just call `resolve/1`
once with that URL and use the result.

## DHCP Option 252 wiring

Each `Interface` subscribes to `["interface", iface, "dhcp_options"]`
and extracts the `:wpad` field (DHCP Option 252) when present. Anything
that writes `dhcp_options` to that property — typically VintageNet's
own udhcpc handler — triggers a PAC fetch and re-publish, provided the
interface config has `proxy: %{mode: :auto}` (without an explicit
`pac_url`) and the interface's `connection` is `:internet` or `:lan`.

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

Early. The PAC parser is deliberately small; real-world PAC files may
exercise predicates this library doesn't handle.
