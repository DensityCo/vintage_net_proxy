# Changelog

## Unreleased

This release rearchitects proxy configuration around per-interface intent
expressed via VintageNet's interface configuration map, instead of the
library's own override store and persistence file.

* Added
  * `VintageNetProxy.Config` — canonical schema for the `:proxy` field
    inside an interface configuration. Modes: `:direct | :auto | :manual`,
    following GNOME's `org.gnome.system.proxy` taxonomy. Includes
    `normalize/1` and `normalize!/1` for validation.

* Changed
  * Proxy intent is now read from `["interface", ifname, "config"]` in
    the VintageNet property table. Add a `:proxy` field to your interface
    config via `VintageNet.configure/3`.
  * WPAD URL (DHCP Option 252) is now consumed from
    `["interface", ifname, "dhcp_options"]` (the `:wpad` key), which is
    what VintageNet already publishes. The library no longer requires a
    separate `wpad_url` property.
  * Persistence is delegated to VintageNet's existing encrypted interface
    config persistence — no separate `/root/vintage_net_proxy/state` file
    is written or read.

* Removed
  * `VintageNetProxy.Persistence` behaviour and implementations
    (`FlatFile`, `Null`). Interface configs are persisted by VintageNet.

* Deprecated
  * `VintageNetProxy.set_manual/1,2` → use `proxy: %{mode: :manual, ...}`
    in the interface config.
  * `VintageNetProxy.set_direct/0` → use `proxy: %{mode: :direct}`.
  * `VintageNetProxy.set_wpad_url/1` → use
    `proxy: %{mode: :auto, pac_url: url}` (or `%{mode: :auto}` for
    DHCP-discovered WPAD).
  * `VintageNetProxy.clear/0` and `clear_wpad_url/0` → remove the
    `:proxy` field via `VintageNet.configure/3`.

  The deprecated functions still work and log a runtime warning; they
  will be removed in a future release.
