# VintageNetProxy

Resolve a system HTTP proxy from a per-interface `:proxy` configuration
field (optionally combined with DHCP Option 252 / WPAD discovery), and
expose the result via the
[VintageNet](https://hex.pm/packages/vintage_net) property table.

Designed to replace polling + file-based IPC + service-restart
architectures (PACrunner, D-Bus, etc.) with event-driven property
subscriptions.

## Installation

Add `vintage_net_proxy` to the deps in your `mix.exs`. The library is
not yet on Hex, so depend on it via Git:

```elixir
def deps do
  [
    {:vintage_net, "~> 0.13"},
    {:vintage_net_proxy, github: "DensityCo/vintage_net_proxy"}
  ]
end
```

Requires Elixir `~> 1.15` and OTP 26 or newer. CI verifies the matrix
1.15-1.19 against OTP 26-28.

Tell the library which interfaces to track, in priority order. The
list usually matches whatever you've passed to `VintageNet.configure/3`
on each interface:

```elixir
# config/config.exs
config :vintage_net_proxy, interfaces: ["eth0", "wlan0"]
```

The Application starts a supervision tree (`VintageNetProxy.Supervisor`)
that subscribes to each listed interface's `config`, `dhcp_options`,
`connection`, and `addresses` properties and publishes the resolved
proxy at `["proxy", "config"]`. Nothing else is required to bring it
up — set the `:proxy` field via `VintageNet.configure/3` and the
library reacts.

## Property surface

The current proxy *model* is published at `["proxy", "config"]` in the
`VintageNet` property table. Stateful modes carry a `{mode, sub_state}`
tuple so that "ready" and "not yet ready" are first-class instead of
being collapsed onto `:unset`:

| Value | Meaning |
|---|---|
| `:unset` | No eligible interface, or eligible interface has no `:proxy` intent |
| `:direct` | Direct mode; bypass any proxy |
| `{:manual, descriptor}` | Explicit proxy from manual mode |
| `{:auto, :ready}` | PAC loaded; call `VintageNetProxy.resolve(url)` per request |
| `{:auto, :no_pac}` | Auto mode but no PAC script loaded — either no URL has been advertised yet, or the last fetch failed (see `VintageNetProxy.Fetcher` logs) |

PAC is inherently per-URL, so under `{:auto, :ready}` the library does
not compress the script down to a single descriptor. The published
value just says "PAC is loaded"; consumers route each outbound URL
through `resolve/1` for a concrete answer.

The `descriptor` carried inside `{:manual, _}` (and returned by
`resolve/1`) looks like:

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

Per-URL: call `VintageNetProxy.resolve/1` at connect time. It returns
`{:ok, directive}` when the library is confident the request should
go that way, or `{:error, reason}` when it isn't. Callers decide
what to do on each error — refuse, wait, alert, or explicitly fall
back to a direct connection.

```elixir
defp connect(url) do
  case VintageNetProxy.resolve(url) do
    {:ok, :direct}                   -> direct_connect(url)
    {:ok, %{} = descriptor}          -> proxied_connect(url, descriptor)
    {:error, :pac_fallthrough}       -> alert_or_wait()       # script is malformed
    {:error, :no_pac}                -> wait_for_dhcp()        # no script (yet, or last fetch failed)
    {:error, :no_proxy_resolved}     -> wait_for_interface()
  end
end
```

Consumers that don't need to distinguish error reasons collapse:

```elixir
case VintageNetProxy.resolve(url) do
  {:ok, decision} -> connect(url, decision)
  {:error, _}     -> connect(url, :direct)
end
```

That collapse is explicit. The library deliberately *doesn't* hide
the error inside `resolve/1` and silently return `:direct` —
"silently bypassing a mandatory proxy" is the exact failure mode the
strict shape is meant to prevent. If your deployment is happy with
direct on resolution failure, you write that collapse; if it isn't,
you handle the reasons individually.

When subscribing to the published property — e.g. so independent
outbound clients (MQTT, WebSocket) can drop and reconnect when the
proxy changes — match on the tagged shape:

```elixir
VintageNet.subscribe(VintageNetProxy.property())

def handle_info({VintageNet, ["proxy", "config"], _, proxy, _}, state) do
  case proxy do
    :unset                  -> {:noreply, hold(state)}          # wait
    :direct                 -> {:noreply, reconnect(state, :direct)}
    {:manual, descriptor}   -> {:noreply, reconnect(state, descriptor)}
    {:auto, :ready}         -> {:noreply, reconnect(state, :auto)}
    {:auto, :no_pac}        -> {:noreply, hold(state)}
  end
end
```

Consumers that just want the simple "is the proxy ready" gate:

```elixir
case proxy do
  :unset -> hold(state)
  _      -> attempt(state, proxy)
end
```

### Why `:direct` and how PAC reports it

A PAC script can hand back `DIRECT` two ways: a rule's predicate
matched and that rule returned `"DIRECT"`, or no rule matched and
the script's catch-all default was `"DIRECT"`. Both are
**information about what the script says**, not errors — they both
come back as `{:ok, :direct}`. Whether default-DIRECT is wrong for
your deployment depends on the deployment; the honest place to
check is a lint over the PAC source ("for external URLs, our PAC
must hit a `PROXY` directive, not `DIRECT`"), not a runtime branch
in the library.

The one case the library does flag as an error is when the script
*structurally* can't reach a verdict — no rule matched *and* no
default could be extracted (malformed script, or every predicate
uses syntax this evaluator silently skips). That returns
`{:error, :pac_fallthrough}` and `VintageNetProxy.PAC` emits a
`Logger.warning`:

```
[warning] VintageNetProxy.PAC: no rules and no default matched for "https://api.example.com/"
```

Operators tailing logs see the parser-level diagnostic; consumers
get the matching error tuple and decide downstream.

## Configuration

All proxy configuration is expressed as a `:proxy` field inside an
interface configuration. The schema follows GNOME's
`org.gnome.system.proxy` taxonomy (`:direct | :auto | :manual`), which is
the de facto Linux desktop convention.

See `VintageNetProxy.Intent` for full schema details.

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

### Why `:lan` counts as eligible

VintageNet classifies an interface's `connection` as
`:disconnected | :lan | :internet`. `:internet` means VintageNet's
own probe (a direct TCP/ICMP check to a configured target like
`1.1.1.1`) succeeded; `:lan` means the link and the IP are up but
that direct probe failed.

On a corporate WPAD network those direct probes are exactly what the
firewall blocks — outbound only works through the proxy — so
VintageNet will park the interface at `:lan` indefinitely. If we
gated proxy publication on `:internet`, the proxy would never get
published on the very networks it's designed for. So this library
treats `:lan` and `:internet` equivalently for proxy resolution:
either is enough to fetch a LAN-hosted PAC and publish the resolved
proxy.

The connectivity checker (see below) is the authoritative "outbound
traffic works" signal — it routes through the resolved proxy and
answers a different question than VintageNet's `:internet` flag.

## Connectivity checker

VintageNet already publishes a per-interface `connection` property
(`:disconnected | :lan | :internet`) that says whether the interface
itself has direct internet reachability. On corporate networks that
discover a proxy via WPAD/PAC, that signal is usually the wrong one to
gate application traffic on — the interface is healthy and reports
`:internet`, but the firewall blocks direct egress and the only path
out is *through the proxy*.

`VintageNetProxy.Connectivity` reports the second signal. It
periodically probes whether the proxy this library has resolved is
actually carrying outbound traffic, and publishes the result so other
parts of the system can subscribe and react:

| Value | Meaning |
|---|---|
| `:unknown` | No probe has run yet (or the checker isn't enabled) |
| `:ok` | The most recent probe succeeded |
| `{:error, reason}` | The most recent probe failed |

```elixir
VintageNetProxy.subscribe_connectivity()

def handle_info({VintageNet, ["proxy", "connectivity"], _old, status, _}, s) do
  case status do
    :ok          -> {:noreply, mark_online(s)}
    {:error, _}  -> {:noreply, mark_offline(s)}
    :unknown     -> {:noreply, s}
  end
end
```

The checker is **off by default**. Enable it by adding a `:connectivity`
keyword list to the library's app environment:

```elixir
config :vintage_net_proxy,
  connectivity: [
    probe_urls: [
      "https://connectivitycheck.gstatic.com/generate_204",
      "https://detectportal.firefox.com/success.txt",
      "https://www.msftncsi.com/ncsi.txt"
    ],
    interval: 60_000
  ]
```

`probe_urls` is a list tried in order, halting on the first success;
`interval` is the milliseconds between automatic probes (defaults to
60s). Under normal operation only the first URL is probed — the
fallbacks only fire when an earlier target itself is broken (vendor
outage, per-host filtering on the proxy), so a multi-URL list adds no
fleet traffic at steady state. The defaults are three well-known
captive-portal probe endpoints across different administrative
domains, so a single-vendor outage doesn't take everyone down. Set
`connectivity: false` (or omit it) to leave the checker off.

### How the probe works

  * For `:direct` (or `:unset`) — TCP-connect to the URL's host and
    port. A successful connect means the device can reach that target
    on that port without a proxy.
  * For `{:manual, descriptor}` with an HTTP/HTTPS scheme —
    TCP-connect to the proxy and send `CONNECT host:port HTTP/1.1`. A
    `200` response means the proxy successfully opened the upstream
    TCP connection on our behalf — i.e. outbound through the proxy is
    working end-to-end.
  * For `{:auto, :ready}` — `resolve/1` is called against the probe URL
    to get a concrete decision, then dispatched as above.
  * For `{:auto, :no_pac}` — falls back to a direct probe so the
    connectivity status honestly reports whether the device can reach
    anything (the answer is usually "no" behind a firewall, which is
    the truthful signal).
  * SOCKS proxies are reported as `{:error, :socks_not_supported}`.
    Supporting them would require a SOCKS client this library
    deliberately doesn't carry; an explicit error is more useful than
    a misleading fallback.

The probe is intentionally minimal: no HTTP body, no TLS handshake,
no captive-portal sniffing. The goal is "did outbound traffic flow,"
not "is the endpoint healthy" — for the latter, applications already
know what to check.

### Isolation

The checker is a single GenServer mounted at the Application level as
a sibling of the main `VintageNetProxy.Supervisor`. It only writes to
`["proxy", "connectivity"]` and only reads `["proxy", "config"]`
(via subscription) and `resolve/1` (when the published value is
`:auto`). A crash in the checker does not perturb the Selector,
Interface processes, or the published proxy value, and vice versa.

### Triggers

Probes fire on four triggers:

  1. Startup (after a configurable `:initial_delay`, default 1s).
  2. Every `:interval` milliseconds.
  3. Whenever the published proxy at `["proxy", "config"]` changes —
     a different proxy means the previous probe result no longer
     describes the current path, so a fresh probe is run immediately.
  4. Whenever `["proxy", "pac_revision"]` ticks — the Selector fires
     this when an active interface's PAC script changes in place
     (same effective URL, new body). The `config` property can't
     distinguish that case (both states publish `{:auto, :ready}`),
     but the rules for what flows through the proxy may have changed,
     so a fresh probe is run.

You can also force an immediate probe synchronously via
`VintageNetProxy.check_connectivity/0`, which returns the new result.

#### `pac_revision`

`["proxy", "pac_revision"]` carries a monotonic value that increments
whenever the active interface's PAC script body changes without the
effective URL changing. It exists so the connectivity checker can
re-probe on PAC reloads that the `config` property can't observe; the
value itself carries no meaning beyond "something changed" and is not
part of the consumer-facing contract.

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
    to its four PropertyTable keys (`config`, `dhcp_options`,
    `connection`, `addresses`), keeps a per-interface
    `Interface.Proxy` value (intent, connection, DHCP options, local
    IP, cached PAC script), and runs `Fetcher.get/1` synchronously
    inside its own mailbox. **The blocking is real but localized**:
    it only stalls that interface's own event processing, not the
    Selector or other interfaces.

  * The `Selector` shrinks to a snapshot aggregator. Each Interface
    pushes its `Interface.Proxy` to the Selector via
    `{:interface_changed, iface, proxy}` after every change. The
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

  * Transient fetch failures retry with exponential backoff
    (`[1s, 2s, 4s, 8s, 16s, 32s, 60s]`, then caps at 60s). The
    canonical case is the DNS race where `dhcp_options` delivers the
    WPAD URL milliseconds before the WPAD host is resolvable —
    without a retry, the Interface would sit on `pac_script: nil`
    until something else nudged it. Any inbound VintageNet event
    cancels the pending retry and resets the attempt counter so a
    real state change re-fetches immediately; a successful fetch
    ends the chain.

### Fast startup

`Interface.init/1` is a true no-op — it just stashes the iface name
and parent on the struct and returns `{:ok, state, {:continue,
:startup}}`. The `handle_continue(:startup, ...)` callback then does
*everything*: subscribes to the per-interface PropertyTable keys,
reads their current values, runs the PAC fetch, and pushes the first
snapshot to the Selector. Effects:

  * `Supervisor.start_link` returns in microseconds regardless of
    whether PAC URLs are reachable, whether VintageNet is responsive,
    or whether the network is up. `init` doesn't talk to anything
    outside the process.
  * Multiple interfaces do their startup work in parallel — each
    `handle_continue` runs in its own process.
  * Application boot doesn't stall on anything network-adjacent.

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

  * `VintageNetProxy.Interface` — the per-interface GenServer.
    Subscribes to PropertyTable, dispatches each event through an
    `Interface.Proxy.put_*` function, supplies `Fetcher.get/1` to
    `Interface.Proxy.refresh_cache/2`, and pushes the updated proxy
    to the Selector. No business logic of its own.

  * `VintageNetProxy.Interface.Proxy` — the per-interface struct and
    every pure query over it: `value/1`, `resolve/2`, `eligible?/1`,
    `effective_pac_url/1`, `snapshot/1`, plus the cache machinery
    (`fetch_target/1`, `cache_script/2`, `refresh_cache/2`,
    `transition/2`). Tested directly without spawning a process.

  * `VintageNetProxy.Intent` — the user-facing proxy intent schema
    (`:direct | :auto | :manual`), its validator (`normalize/1`,
    `normalize!/1`), and the `adopt/2` helper that turns a VintageNet
    config payload into a normalized intent, logging on invalid
    input.

  * `VintageNetProxy.Selector` — a thin GenServer (~35 lines). One
    handle_info clause for `{:interface_changed, ...}`, two
    handle_calls for `status` and `resolve`. It owns no fetch logic
    and no PropertyTable subscriptions.

  * `VintageNetProxy.Roster` — a pure module: priority list of
    interfaces plus `%{iface => Interface.Proxy.t}`. Knows how to
    find the active interface and to compute the published `value`,
    the `resolve` result, and the `status` map.

  * `VintageNetProxy.Publisher` — owns the single public PropertyTable
    key this library writes (`["proxy", "config"]`). Three calls:
    `put/1`, `get/0`, `property/0`. Selector is the only caller.

  * `VintageNetProxy.Fetcher` — synchronous `Fetcher.get(url)` using
    `:httpc`. Has a 5-second timeout and a 256 KiB body cap. Logs a
    warning on every failure path so callers don't have to thread
    error reasons through state. Passes
    `ssl: [verify: :verify_none]` explicitly — required to avoid OTP
    26+'s eager `:public_key.cacerts_get/0` crash on systems with no
    OS CA store (Nerves images), and consistent with the WPAD trust
    model where the LAN, not TLS, is the trust boundary.

  * `VintageNetProxy.Wpad` — DNS-WPAD URL construction (option 15 →
    `http://wpad.<domain>/wpad.dat`) and DHCP-option extraction
    (`from_dhcp_options/1` pulls option 252 and option 15).

  * `VintageNetProxy.Addresses` — pulls the first IPv4 address from
    VintageNet's `addresses` property into the dotted-quad string
    PAC's `myIpAddress()` needs.

  * `VintageNetProxy.PAC`, `PAC.Predicate`, `PAC.IP`, `PAC.DNS`,
    `PAC.Clock` — the PAC script evaluator (see "PAC subset" below).
    `PAC.DNS` owns an ETS-backed DNS cache used by `dnsResolve` /
    `isResolvable`; `PAC.Clock` provides the wallclock and range
    checks used by `weekdayRange` / `timeRange`.

  * `VintageNetProxy.Connectivity`, `Connectivity.Probe` — the
    optional connectivity checker; lives outside the main supervision
    tree so it can't perturb proxy resolution. See "Connectivity
    checker" above.

## Persistence

There is no separate persistence layer. VintageNet already persists
interface configurations (encrypted, with the same machinery that hides
WiFi passphrases), so the `:proxy` field gets persisted alongside the
rest of the interface config and is restored on boot automatically.

## Per-URL resolution

PAC scripts are a function from URL → proxy decision, so for `:auto`
mode the published property carries `{:auto, :ready}` once the script
is loaded, not a descriptor. Consumers call `resolve/1` per request to
get the concrete answer for that URL:

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

## WPAD discovery

For `:auto` proxy intent with no explicit `:pac_url`, the library tries
two discovery paths in order, both driven off the
`["interface", iface, "dhcp_options"]` property that VintageNet's
udhcpc handler populates from each lease:

1. **DHCP Option 252 (`wpad`)** — if the lease included a WPAD URL
   directly, that's what gets fetched. This is the modern path and what
   most corporate WPAD-aware DHCP servers advertise.
2. **DNS-WPAD fallback** — if option 252 wasn't present but DHCP option
   15 (`domain`) was, the library constructs
   `http://wpad.<domain>/wpad.dat` and fetches that. This is the
   classic WPAD discovery path used by networks that publish PAC via
   DNS only.

Either signal triggers a PAC fetch and re-publish, provided the
interface's `connection` is `:internet` or `:lan`. An explicit
`pac_url` in the proxy config wins over both DHCP-derived paths.

The DNS-WPAD step deliberately does **not** walk up the DNS hierarchy
(`wpad.eng.corp.example` → `wpad.corp.example` → ...). It constructs
exactly one URL from the exact DHCP-supplied domain. Walking up is a
known WPAD spoofing vector and is not implemented; if a deployment
needs multiple-domain discovery, set `:pac_url` explicitly.

## PAC subset

The bundled PAC evaluator handles the patterns found in typical corporate
WPAD scripts.

**Predicate atoms:**
- `shExpMatch(host, "<glob>")` — `*` and `?` wildcards
- `shExpMatch(url, "<glob>")` — same matcher, against the full URL
- `dnsDomainIs(host, ".<suffix>")` — case-insensitive suffix match
- `isPlainHostName(host)`
- `localHostOrDomainIs(host, "<hostdom>")` — matches the
  fully-qualified `hostdom`, or `host` when it's the unqualified
  form of `hostdom` (e.g. `intranet` matches `intranet.corp.example`)
- `isInNet(host, "<net>", "<mask>")` — IPv4 literal hosts only
- `isInNet(myIpAddress(), "<net>", "<mask>")` — checks the device's
  own IPv4 address, taken from the active interface's `addresses`
  property. Common pattern for subnet-aware routing: "if I'm on
  10.1.x.x, use site-A proxy; on 10.2.x.x, use site-B." When no
  IPv4 address is available (interface down, IPv6-only lease) the
  predicate evaluates to false and the rule falls through.
- `isInNet(dnsResolve(host), "<net>", "<mask>")` — resolves the
  URL's host via DNS (or `:inet_res.lookup/4`, with a 500ms
  timeout) before the subnet check. The canonical "bypass internal
  subnets" pattern. Resolutions are cached for 60s on hits / 10s
  on misses by `VintageNetProxy.PAC.DNS`. A failed lookup returns
  `:error` and the rule falls through.
- `isResolvable(host)` — true when the host resolves through the
  same cached resolver.
- `weekdayRange("MON", ["FRI"], ["GMT"])` — current weekday in range.
  Wraps when `wd2 < wd1` (e.g. `"FRI", "MON"` covers Fri/Sat/Sun/Mon).
  Optional trailing `"GMT"` switches from local to UTC time.
- `timeRange(...)` — current time-of-day in `[start, end)`. Arities
  1 (hour), 2 (hour-range), 4 (hh:mm), 6 (hh:mm:ss); each
  optionally with a trailing `"GMT"`. No wrap-around — night-shift
  ranges crossing midnight require two `timeRange` calls combined
  with `||`.
- `dateRange(...)` — current date in range. Args are classified by
  type: string → month (`"JAN"`–`"DEC"`), int [1..31] → day of
  month, int [1000..9999] → year. Valid arities: 1 / 2 / 4 / 6 in
  fixed type sequences (e.g. `(day, month, day, month)` for a
  within-a-year range). Day, month, and day-month ranges wrap;
  year, month-year, and full-date ranges do not. Optional trailing
  `"GMT"`.
- `host == "<literal>"` / `host === "<literal>"`

**Boolean composition:** `||`, `&&`, `!`, and parentheses. Standard
precedence (`!` > `&&` > `||`); left-associative.

**Directives:**
- `"DIRECT"` → `:direct`
- `"PROXY host:port"` / `"HTTP host:port"` → `%{scheme: :http, ...}`
- `"HTTPS host:port"` → `%{scheme: :https, ...}`
- `"SOCKS host:port"` / `"SOCKS4 host:port"` → `%{scheme: :socks4, ...}`
- `"SOCKS5 host:port"` → `%{scheme: :socks5, ...}`
- Fallback lists (`"PROXY a:1; PROXY b:2; DIRECT"`) — only the first
  recognized entry is returned

Anything outside this subset (unsupported atom, malformed predicate, parse
error) evaluates to false and the rule falls through. Malformed scripts
return `:direct`.

DNS-resolving variants (`dnsResolve`, `isResolvable`, and
`isInNet(dnsResolve(host), ...)`) use a cached resolver
(`VintageNetProxy.PAC.DNS`) with a 500ms per-call timeout. Resolutions
hit `:inet_res.lookup/4` directly (bypassing the OS resolver and
`/etc/hosts`); IPv4 literals short-circuit without touching DNS or the
cache. The cache GenServer lives in the main supervision tree; when
it isn't running (unit tests), the resolver returns `:error` so
predicates fall through gracefully without crashing.

Time-based predicates (`weekdayRange`, `timeRange`) use the
wallclock injected via `:now` on `find_proxy/3`; the default
(`VintageNetProxy.PAC.Clock.now/1`) uses Erlang's `:calendar`
module, so no timezone database is required. Tests pass a stub fn
that returns a fixed `NaiveDateTime`.

IPv6 variants (`dnsResolveEx`, `isResolvableEx`, `myIpAddressEx`,
`isInNetEx`) and `dnsDomainLevels` are not implemented; extend
`VintageNetProxy.PAC.Predicate` if a deployment needs them.

## Why no Duktape / PACrunner

A full JavaScript engine is the correct general solution but a poor fit
for embedded Nerves devices: ~1MB of binary, a C dependency, and a
sandbox we'd have to reason about for security. The simple subset
evaluator fits in ~150 lines of Elixir and covers the cases real
corporate networks actually deploy. Revisit if a customer ships a PAC
file that needs the full grammar.

## Testing

Unit and Selector/Interface tests run against an in-process `:gen_tcp`
HTTP fixture and execute under `mix test`. The integration suite
exercises the library against a real `nginx` (serving the PAC) and a
real `tinyproxy` (the proxy the WPAD points to); see
[`dev/README.md`](dev/README.md):

```sh
docker compose -f dev/docker-compose.yml up -d
mix test --include integration
docker compose -f dev/docker-compose.yml down
```

CI runs both suites on every push and PR across an Elixir 1.15 → 1.19
matrix paired with OTP 26 → 28.

### What's been verified end-to-end

- `VintageNetEthernet.normalize/1` and `VintageNetWiFi.normalize/1`
  preserve the `:proxy` field for all four shapes (`:direct`,
  `:manual` with credentials, `:auto` with explicit `pac_url`, `:auto`
  for DHCP-discovered WPAD).
- A real `VintageNet.OSEventDispatcher.dispatch(["bound"], env)` with a
  realistic udhcpc env hash (including `"wpad" => ...` from DHCP
  option 252) flows through the udhcpc-env parser, lands as `:wpad` in
  `dhcp_options`, and triggers a PAC fetch that publishes
  `{:auto, :ready}`.
- An actual HTTP `GET` issued to the descriptor `resolve/1` returns
  reaches the upstream — observable in tinyproxy's access log.

The remaining gap is a deployment on real Nerves hardware against a
network that advertises WPAD via DHCP, which is the only thing the
host-side suite can't reproduce.

## Status

Production-shaped, not production-deployed. The PAC parser handles the
patterns found in typical corporate WPAD files; real-world PAC files
may exercise predicates this library doesn't handle (DNS-resolving
`isInNet`, `myIpAddress`, `weekdayRange`, etc.) — extend
`VintageNetProxy.PAC.Predicate` when a new pattern shows up.
