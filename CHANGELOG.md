# Changelog

## Unreleased

Initial design. Proxy configuration is expressed as a `:proxy` field
inside a VintageNet interface configuration map; the library reads
that intent from `["interface", ifname, "config"]` and combines it
with DHCP-discovered WPAD URLs (`["interface", ifname,
"dhcp_options"]`, `:wpad` and `:domain` keys) to produce the resolved
proxy at `["proxy", "config"]`.

### Configuration & schema

* `VintageNetProxy.Config` — canonical schema (`:direct | :auto |
  :manual`, following GNOME's `org.gnome.system.proxy` taxonomy) with
  `normalize/1` validation and `to_descriptor/1` for runtime
  materialization.
* Persistence is delegated to VintageNet's encrypted interface config
  persistence — no separate state file is written.

### Property surface

* `["proxy", "config"]` is mode-tagged so loading and error states
  are first-class instead of being collapsed onto `:unset`:
  * `:unset` — no eligible interface, or no `:proxy` intent
  * `:direct` — direct mode
  * `{:manual, descriptor}` — explicit proxy
  * `{:auto, :ready}` — PAC loaded; call `resolve/1` per URL
  * `{:auto, :no_url}` — auto mode, no PAC URL available yet
  * `{:auto, {:error, reason}}` — PAC fetch failed
* `["proxy", "pac_revision"]` — monotonic tick the Selector publishes
  when the active interface's PAC script changes in place (same
  effective URL, new body). Internal signal for the connectivity
  checker; not part of the consumer-facing contract.
* `["proxy", "connectivity"]` — published by the optional
  connectivity checker; `:unknown | :ok | {:error, reason}`.

### WPAD discovery

* DHCP option 252 (`wpad`) — modern path.
* DNS-WPAD fallback — when option 252 is absent, the library
  constructs `http://wpad.<domain>/wpad.dat` from DHCP option 15
  (`domain`) and fetches that. No DNS hierarchy walking (a known
  spoofing vector).

### Connectivity checker

* `VintageNetProxy.Connectivity` — optional, off by default. Enable
  via `config :vintage_net_proxy, connectivity: [...]`.
* Lives at the Application level as a sibling of the main
  supervisor; a crash in either tree doesn't cascade.
* Probes with a configurable list of URLs (default: three captive-
  portal endpoints across different administrative domains). First
  success wins; fallbacks only fire when an earlier target is broken.
* `TCP`-connect probes for `:direct`; HTTP `CONNECT` for HTTP/HTTPS
  proxies; SOCKS reported as `{:error, :socks_not_supported}`.
* Re-probes on: startup, every `:interval` ms, `["proxy", "config"]`
  changes, `["proxy", "pac_revision"]` ticks.

### PAC source distinction & resolve result shape

* `PAC.find_proxy/2` returns a `{source, directive}` tuple — `{:rule, _}`
  when a rule fired, `{:default, _}` when no rule matched and the script
  had a default, `{:fallthrough, :direct}` when neither applied. Lets the
  library tell "PAC intentionally said `DIRECT`" apart from "PAC silently
  fell through to `DIRECT`."
* `VintageNetProxy.resolve/1` returns `{:ok, directive}` for a decisive
  answer and `{:error, reason}` when the library can't confidently route
  the URL — `:pac_default_direct`, `:pac_fallthrough`, `:no_pac_url`,
  `{:pac_fetch_failed, _}`, `:no_proxy_resolved`. Callers explicitly
  decide on each error case (refuse / wait / alert / fall back to
  direct); the library never silently bypasses a mandatory proxy.
* The fall-through log uses the source tag to pick a level: `:rule` is
  silent (working as designed), `{:default, :direct}` logs at `:info`,
  `:fallthrough` logs at `:warning`. Operators investigating "why did
  this request go direct" see the suspicious cases without enabling
  debug.

### Public API

* `VintageNetProxy` — `property/0`, `subscribe/0`, `unsubscribe/0`,
  `get/0`, `status/0`, `resolve/1`.
* Connectivity — `connectivity_property/0`,
  `subscribe_connectivity/0`, `unsubscribe_connectivity/0`,
  `connectivity/0`, `check_connectivity/0`.
