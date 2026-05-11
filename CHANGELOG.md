# Changelog

## Unreleased

Initial design. Proxy configuration is expressed as a `:proxy` field
inside a VintageNet interface configuration map; the library reads that
intent from `["interface", ifname, "config"]` and combines it with
DHCP-discovered WPAD URLs (`["interface", ifname, "dhcp_options"]`,
`:wpad` key) to produce the resolved proxy at `["proxy", "config"]`.

* `VintageNetProxy.Config` — canonical schema (`:direct | :auto | :manual`,
  following GNOME's `org.gnome.system.proxy` taxonomy) with `normalize/1`
  validation and `to_descriptor/1` for runtime materialization.
* Persistence is delegated to VintageNet's encrypted interface config
  persistence — no separate state file is written.
* Public API: `property/0`, `subscribe/0`, `unsubscribe/0`, `get/0`,
  `status/0`, `resolve/1`, `set_target_url/1`, `get_target_url/0`.
