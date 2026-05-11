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

## Architecture

```
VintageNetProxy.Supervisor              (rest_for_one)
├── VintageNetProxy.InterfaceRegistry   (Registry: iface name → pid)
├── VintageNetProxy.Selector            (GenServer: snapshot aggregator)
└── VintageNetProxy.InterfaceSupervisor (one_for_one)
        ├── VintageNetProxy.Interface (eth0)   (GenServer: one per iface)
        ├── VintageNetProxy.Interface (wlan0)  (GenServer: one per iface)
        └── ...
```

### Why one GenServer per interface

PAC discovery requires fetching a script over HTTP, which is blocking
and can be slow (5-second timeout if a WPAD URL is unreachable). The
property changes that *trigger* a fetch — `connection` flipping up, a
new DHCP wpad, a config edit — flow in continuously, and consumers of
`resolve/1` and `status/0` need answers in microseconds, not seconds.

A single-GenServer design forces a tradeoff: either block the mailbox
on the fetch (so `resolve/1` waits up to 5 seconds during an in-flight
PAC load) or move the fetch to a side `Task` (which then needs URL
tagging, stale-result rejection, and a coordination handshake to keep
the cached script consistent).

Per-interface GenServers split the problem geographically:

  * Each `Interface` owns one network interface end-to-end — subscribes
    to its three PropertyTable keys (`config`, `dhcp_options`,
    `connection`), holds the per-interface state (intent, connection,
    DHCP wpad, cached `pac_script`), and runs `Fetcher.get/1`
    synchronously inside its own mailbox. **The blocking is real but
    localized**: it only stalls that interface's own event processing,
    not the Selector or other interfaces.

  * The `Selector` shrinks to a snapshot aggregator. Each Interface
    pushes its full state to the Selector via
    `{:interface_changed, iface, state}` after every change. The
    Selector keeps the latest snapshot per interface in a `Roster`,
    picks the highest-priority eligible interface, and publishes the
    resulting proxy value. **`resolve/1` and `status/0` are served
    from cached snapshots and never block on a fetch.**

  * Stale-script handling falls out for free. Because each Interface's
    mailbox is single-threaded, a fetch runs against whatever URL was
    effective when the fetch started. Subsequent property changes
    queue up and are processed *after* the fetch completes. No URL
    tagging or "is this result still valid?" check is needed in the
    code path.

### Fast startup

`Interface.init/1` reads PropertyTable values (fast) and returns
immediately with `{:ok, state, {:continue, :startup}}`. The
`handle_continue(:startup, ...)` callback does the blocking PAC fetch
*after* init returns. Effects:

  * `Supervisor.start_link` returns in ~5ms regardless of whether PAC
    URLs are reachable (verified: 5057ms → 5ms with an unreachable PAC
    URL pre-populated in the PropertyTable).
  * Multiple interfaces fetch their PAC scripts in parallel — each
    `handle_continue` runs in its own process.
  * Application boot doesn't stall on the network coming up.

### Supervision

Top-level `:rest_for_one` ensures the Selector and the
InterfaceSupervisor restart together when the Selector dies — fresh
Interfaces re-push their initial snapshots to the fresh Selector and
the system recovers. The inner `InterfaceSupervisor` is `:one_for_one`,
so a crash in one Interface doesn't disturb its siblings: only that
interface restarts, re-reads its state, and re-fetches its PAC.

Interfaces are registered via the
`VintageNetProxy.InterfaceRegistry` (`{:via, Registry, ...}`), so they're
discoverable by interface name —
`VintageNetProxy.Interface.get(iface)` returns the live state for
debugging or external inspection.

### Module map

  * `VintageNetProxy.Interface` — both the per-interface struct (the
    shape of a snapshot) and the GenServer that maintains it. Pure
    helpers (`eligible?`, `value`, `resolve`, `effective_pac_url`,
    `snapshot`) operate on the struct and are tested without a
    process.

  * `VintageNetProxy.Selector` — a thin GenServer (~35 lines). One
    handle_info clause for `{:interface_changed, ...}`, two
    handle_calls for `status` and `resolve`. It owns no fetch logic
    and no PropertyTable subscriptions.

  * `VintageNetProxy.Roster` — a pure module: priority list of
    interfaces plus `%{iface => Interface.t}`. Knows how to find the
    active interface and to compute the published `value`, the
    `resolve` result, and the `status` map.

  * `VintageNetProxy.Publisher` — owns the single public PropertyTable
    key this library writes (`["proxy", "config"]`). Three calls:
    `put/1`, `get/0`, `property/0`. Selector is the only caller.

  * `VintageNetProxy.Fetcher` — synchronous `Fetcher.get(url)` using
    `:httpc`. Has a 5-second timeout and a 256 KiB body cap.

  * `VintageNetProxy.PAC`, `PAC.Predicate`, `PAC.IP` — the PAC
    script evaluator (see "PAC subset" below).

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

**Predicate atoms:**
- `shExpMatch(host, "<glob>")` — `*` and `?` wildcards
- `dnsDomainIs(host, ".<suffix>")` — case-insensitive suffix match
- `isPlainHostName(host)`
- `isInNet(host, "<net>", "<mask>")` — IPv4 literal hosts only (no DNS)
- `host == "<literal>"` / `host === "<literal>"`

**Boolean composition:** `||`, `&&`, `!`, and parentheses. Standard
precedence (`!` > `&&` > `||`); left-associative.

**Directives:**
- `"DIRECT"` → `:direct`
- `"PROXY host:port"` → `%{scheme: :http, ...}`
- `"HTTPS host:port"` → `%{scheme: :https, ...}`
- `"SOCKS host:port"` / `"SOCKS4 host:port"` → `%{scheme: :socks4, ...}`
- `"SOCKS5 host:port"` → `%{scheme: :socks5, ...}`
- Fallback lists (`"PROXY a:1; PROXY b:2; DIRECT"`) — only the first
  recognized entry is returned

Anything outside this subset (unsupported atom, malformed predicate, parse
error) evaluates to false and the rule falls through. Malformed scripts
return `:direct`.

`isInNet` deliberately matches only when `host` is already an IPv4
literal — embedding DNS resolution inside PAC evaluation would make proxy
lookup network-dependent. Real-world WPADs typically gate the IP arm with
`isPlainHostName(host) || isInNet(host, ...)`, which works correctly under
this rule.

If real-world PAC files need more (DNS-resolving `isInNet`, `myIpAddress`,
`weekdayRange`, credential parsing, etc.), extend
`VintageNetProxy.PAC.Predicate`.

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
