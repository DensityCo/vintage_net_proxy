# Dev environment

A docker-compose stack that exercises this library against real HTTP
infrastructure rather than the in-process `:gen_tcp` fixture the unit
tests use.

## What's here

- **`wpad.dat`** — a realistic enterprise-style PAC script. Edit
  freely; nginx serves it without caching.
- **`docker-compose.yml`** — two containers:
  - `nginx` on `localhost:18080` serving `wpad.dat`
  - `tinyproxy` on `localhost:18888` as the actual HTTP proxy

## Bring it up

```sh
docker compose -f dev/docker-compose.yml up -d
```

Verify both services are reachable:

```sh
curl -s http://localhost:18080/wpad.dat | head -3
# function FindProxyForURL(url, host) {
#   ...

curl -sx http://localhost:18888 http://httpbin.org/ip
# {
#   "origin": "<your-ip>"
# }
```

## Run the integration test against it

```sh
mix test --include integration
```

The integration suite is tagged `:integration` and excluded by default
so a fresh checkout's `mix test` still passes without docker. The
tagged tests live in `test/vintage_net_proxy/proxy_end_to_end_test.exs`.

## Iterate on the WPAD

Edit `wpad.dat` on the host — nginx serves the file directly from the
mounted volume, so the change is live immediately. Make the library
re-fetch by toggling the `connection` property of your test interface:

```elixir
iface = "eth0"
PropertyTable.put(VintageNet, ["interface", iface, "connection"], :disconnected)
PropertyTable.put(VintageNet, ["interface", iface, "connection"], :internet)
```

(The `:disconnected` drops the cached `pac_script`; the subsequent
`:internet` triggers a fresh fetch.)

## Tear down

```sh
docker compose -f dev/docker-compose.yml down
```
