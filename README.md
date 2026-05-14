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
and `connection` properties and publishes the resolved proxy at
`["proxy", "config"]`. Nothing else is required to bring it up — set
the `:proxy` field via `VintageNet.configure/3` and the library
reacts.

## Property surface

The current proxy *model* is published at `["proxy", "config"]` in the
`VintageNet` property table. Stateful modes carry a `{mode, sub_state}`
tuple so loading and error states are first-class instead of being
collapsed onto `:unset`:

| Value | Meaning |
|---|---|
| `:unset` | No eligible interface, or eligible interface has no `:proxy` intent |
| `:direct` | Direct mode; bypass any proxy |
| `{:manual, descriptor}` | Explicit proxy from manual mode |
| `{:auto, :ready}` | PAC loaded; call `VintageNetProxy.resolve(url)` per request |
| `{:auto, {:error, reason}}` | PAC fetch failed; sticks until the URL changes, the interface flaps, or the next external event re-fetches |

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
    {:error, :no_pac_url}            -> wait_for_dhcp()
    {:error, {:pac_fetch_failed, _}} -> wait_or_alert()
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
    {:auto, {:error, _}}    -> {:noreply, alert_or_hold(state)}
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
  * For `{:auto, {:error, _}}` — falls back to a direct probe so the
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
- `isInNet(host, "<net>", "<mask>")` — IPv4 literal hosts only (no DNS)
- `isInNet(myIpAddress(), "<net>", "<mask>")` — checks the device's
  own IPv4 address, taken from the active interface's `addresses`
  property. Common pattern for subnet-aware routing: "if I'm on
  10.1.x.x, use site-A proxy; on 10.2.x.x, use site-B." When no
  IPv4 address is available (interface down, IPv6-only lease) the
  predicate evaluates to false and the rule falls through.
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
