# tunnel-broker

A self-hostable reverse HTTP tunnel broker for HyperBEAM nodes.

Run this on a machine with a public IP and a wildcard domain, and any HyperBEAM
node — behind NAT, on mobile data, roaming between networks — becomes reachable
at a stable public URL derived from its own address:

```
https://<node-address-base32>.tunnel.example.com/~hyperbuddy@1.0/index
```

The node holds long-poll registrations outbound to the broker, so it needs no
inbound ports, no port forwarding, and no static IP.

**Responses are byte-for-byte identical to hitting the node directly.** Status
codes, redirects, content types and bodies of any size all survive the hop —
verified against a direct LAN request for every path, including a 4.2 MB
JavaScript bundle and a 307 redirect (see [Verifying](#verifying)).

## Why you might want your own

Anyone can point a node at a public broker, and there is no reason that has to
be someone else's. Running your own gives you:

- **Your own domain**, so your nodes' public URLs are yours.
- **Full HTTP fidelity.** Some brokers can only carry a small response body and
  silently drop status codes and headers — redirects break, MIME types vanish,
  and real pages never arrive. This one relays the complete HTTP response.
- **No third-party dependency** in the path between the public internet and
  your node, and no third party seeing that traffic.
- **Operational control** — your logs, your rate limits, your uptime.

## How it works

```
   public client                broker (this)                 your node
        │                            │                            │
        │                            │◀── POST /~tunnel@1.0/register (long poll)
        │                            │      held open until work exists
        │                            │                            │
        │── GET https://<b32>.you ──▶│                            │
        │   (Host names the node)    │── returns the request ────▶│
        │                            │                            │ executes it
        │                            │                            │ against its
        │                            │                            │ own listener
        │                            │◀── POST /~tunnel@1.0/response
        │◀── full HTTP response ─────│    (status + headers + body)
```

The first DNS label of the Host header is the node's 32-byte address in
base32 (52 chars, lowercase). The broker decodes it, matches it to a live
registration, and relays. A `node-<b32>.…` prefix is also accepted.

### The wire protocol, and why it looks like this

Two design choices are load-bearing, both learned the hard way:

1. **The forwarded request is inlined** into the top level of the work message
   (its `path`, `method` and scalar headers become top-level keys) rather than
   nested under a `request` key. A nested sub-message is turned into a
   content-addressed *link* by the HTTP codec, and that link does not survive
   the hop to a different machine — the receiver fails with
   `necessary_message_not_found`. Inlined scalars have no such indirection.

2. **The response is inlined the same way**, announced by
   `tunnel-response: envelope`, carrying `status`, `body` and a JSON
   `tunnel-headers` map. This is what preserves redirects, content types and
   large bodies end to end.

A `tunnel-mode: envelope` marker in the work message tells the node this broker
can ingest a full envelope. Brokers that cannot simply never set it, and nodes
fall back to returning a plain body — so a node speaking this protocol still
works against a less capable broker.

## Requirements

- A host with a public IP.
- A wildcard DNS record: `*.tunnel.example.com` → that host.
- A **wildcard TLS certificate**, which means an ACME **DNS-01** challenge
  (HTTP-01 cannot issue wildcards). The included `Caddyfile` does this.
- A HyperBEAM runtime (BEAM files + the preloaded device store). Any HyperBEAM
  release works; you can also lift the one out of an AndEE APK
  (`assets/andee-runtime.zip`).

## Install

```sh
git clone <this repo> /opt/tunnel-broker
cd /opt/tunnel-broker

# Provide a HyperBEAM runtime (contains erlang/<abi>/lib/... and the
# preloaded device store). Either unpack a release, or:
#   unzip andee-runtime.zip -d /opt/tunnel-broker/runtime
export HB_RUNTIME=/opt/tunnel-broker/runtime

./run.sh
```

`run.sh` compiles `src/` against the runtime and starts the broker. On first
run it creates `broker-wallet.json` — the broker's own stable identity. Keep it;
delete it and the broker gets a new identity (this does not change your nodes'
public URLs, which derive from *their* addresses, not the broker's).

> **The preloaded device store is required.** It is how a HyperBEAM node
> resolves its codecs. Without it the broker starts, binds, and then hangs on
> the first request while it tries to resolve `httpsig@1.0` over the network.
> If you see that, `HB_RUNTIME` is wrong or incomplete.

### Configuration — `config/broker.json`

```json
{
  "port": 8080,
  "wallet": "broker-wallet.json",
  "store": [
    { "store-module": "hb_store_volatile", "name": "tunnel-broker-store" }
  ]
}
```

- `port` — where the broker listens. Keep it on loopback and put TLS in front.
- `wallet` — path to the broker's keyfile, or `"ephemeral"` for a throwaway key.

### TLS and DNS

Edit `Caddyfile` (domain, DNS provider, API token) and run Caddy with the
provider plugin built in:

```sh
xcaddy build --with github.com/caddy-dns/cloudflare
CLOUDFLARE_API_TOKEN=... caddy run
```

The proxy must allow long-held requests: registrations are held open for ~45s.
The provided config sets generous timeouts and disables response buffering.

### As a service

`deploy/tunnel-broker.service` (systemd) and `deploy/tunnel-broker.initd`
(OpenRC) are included. Both expect the install at `/opt/tunnel-broker` with
`HB_RUNTIME` set; adjust to taste.

## Pointing a node at your broker

Any HyperBEAM node with the `tunnel@1.0` device can connect at runtime — no
rebuild, no restart:

```sh
curl -X POST http://<your-node>:8734/~tunnel@1.0/connect \
  -H 'content-type: application/json' \
  -d '{"peer":"https://tunnel.example.com","workers":3}'
```

To make it automatic, add a `start` hook to the node's config:

```json
{
  "on": {
    "start": [
      {
        "device": "tunnel@1.0",
        "method": "POST",
        "path": "connect",
        "peer": "https://tunnel.example.com",
        "workers": 3,
        "hook": { "result": "ignore" }
      }
    ]
  }
}
```

**Use 3 or more workers.** A worker is consumed while it executes a request, so
a single worker leaves the tunnel unavailable for the duration of every request.
With several, the tunnel stays continuously answerable. The broker also
grace-queues requests for an address that registered recently, so a brief gap
between long-polls never surfaces as an error to the public caller.

The node's public hostname is `base32(address)` — lowercase, unpadded — as the
first label under your domain. Compute it with:

```sh
python3 -c "
import base64,sys
raw = base64.urlsafe_b64decode(sys.argv[1] + '=')
print(base64.b32encode(raw).decode().lower().rstrip('='))" <node-address>
```

Note that a node with an ephemeral (session) wallet gets a new address, and
therefore a new public hostname, every time it restarts.

## Verifying

`test/broker_driver.erl` starts a tunnelled node, connects it to a running
broker, and compares public requests (routed **only** by Host header) against
direct requests to the node:

```
== broker parity (public traffic routed by Host only) ==
/~meta@1.0/info/address            MATCH
/                                  MATCH        (307 + Location preserved)
/~hyperbuddy@1.0/index             MATCH        (2,285 B text/html)
/~hyperbuddy@1.0/bundle.js         MATCH        (4,230,990 B text/javascript)

ALL MATCH
```

`MATCH` means identical status, identical body bytes, and identical `location`
and `content-type`.

## Operational notes

- **Fault containment.** A request that cannot be forwarded fails only its own
  caller; the worker registration is returned to the pool and the broker keeps
  serving every other node. A node that dies mid-request does not wedge the
  broker.
- **Observability.** `GET /~tunnel@1.0/status` (with
  `Accept: application/json`) reports registered addresses, pending requests and
  open registrations.
- **Exposure.** Any node that registers becomes publicly reachable at its
  address's hostname. The broker does not authenticate registrations, so an open
  broker is an open relay for anyone who knows it. If that is not what you want,
  put an allowlist of node addresses in front of `/~tunnel@1.0/register`, or
  firewall the registration endpoint to known clients.
- **Ephemeral wallets.** If your nodes use session wallets, their public URLs
  rotate on restart. Persist a wallet on the node if you need a stable URL.

## Layout

```
src/tunnel_broker.erl       broker bootstrap (config, wallet, node start)
src/dev_tunnel.erl          tunnel@1.0 device: request hook, client, envelope
src/dev_tunnel_server.erl   broker state: registrations, dispatch, fault containment
config/broker.json          broker config
Caddyfile                   wildcard TLS + reverse proxy
deploy/                     systemd + OpenRC units
test/broker_driver.erl      end-to-end parity check against a live broker
run.sh                      compile + launch
```
