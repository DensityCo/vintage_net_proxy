import Config

# Don't try to touch /etc/resolv.conf or persist anything from a host test run.
config :vintage_net,
  resolvconf: "/tmp/vintage_net_proxy_test_resolv.conf",
  persistence: VintageNet.Persistence.Null,
  tmpdir: "/tmp/vintage_net_proxy_test",
  config: []

# Don't auto-start the Server — each test starts its own with a unique iface.
config :vintage_net_proxy, server_opts: false
