# hyperbeam-tunnel

A reverse HTTP tunnel for HyperBEAM / PermawebOS nodes, shipped as a single
device: **`tunnel@1.0`**. Add the device to a node's device package and merge a
few keys into its config, and that node can either **publish itself** at a stable
public URL while behind NAT, or **act as the tunnel provider** for others.

```
https://<node-address-base32>.tunnel.example.com/~hyperbuddy@1.0/index
```

**Responses are byte-for-byte identical to hitting the node directly** — status
codes, redirects, content types, and bodies of any size all survive the hop
(verified for a 307 redirect, a 2.3 KB page, and a 4.2 MB JS bundle; see
[Verifying](#verifying)).

## Device + config, nothing else

The tunnel is not a bespoke server. It is the `tunnel@1.0` device plus config,
running on a **stock** HyperBEAM node. This is proven — `test/stock_broker_proof.erl`
starts a broker from a stock `hb_http_server:start_node/1` with only the device
(from the device package) and an `on/request` config hook, and gets full parity.

Because it is device + config on the shared HyperBEAM base, **what you prove on
one PermawebOS target you inherit on the others**: prove it on an
[AndEE](https://permawebos.arweave.net) phone (fast to iterate with `adb`) and a
[LapEE](https://permawebos.arweave.net/run) laptop appliance inherits the exact
same device 1:1. A LapEE tunnel provider is the intended production form — a
hardened, attested appliance, so the provider is not a weaker trust link than the
nodes it fronts. See **[LAPEE.md](LAPEE.md)**.

## Two roles, both pure config

Add `tunnel@1.0` to the node's device package, then **merge** the relevant keys
into the node's own config (e.g. append to a bundler config — this is the same
overlay merge PermawebOS already does; you do **not** ship a separate config
file). The exact keys and a worked bundler example are in
**[config/README.md](config/README.md)**.

- **Provider (broker):** `config/tunnel-provider.fragment.json` — an `on/request`
  hook + a `trusted-devices` pin. The node routes public traffic for
  `<b32>.<domain>` to whichever node registered that address. It coexists with an
  existing `on/request` hook such as `manifest@1.0` (proven in
  `test/merge_proof.erl`).
- **Client (publish yourself):** `config/tunnel-client.fragment.json` — an
  `on/start` hook that dials a provider on boot with a worker count.

## How it works

```
   public client                provider (broker)             your node
        │                            │                            │
        │                            │◀── POST /~tunnel@1.0/register (long poll)
        │── GET https://<b32>.you ──▶│── returns the request ────▶│ executes it
        │   (Host names the node)    │                            │ locally
        │◀── full HTTP response ─────│◀── POST /~tunnel@1.0/response
```

The first DNS label of the Host header is the node's 32-byte address in base32
(52 chars, lowercase); the provider decodes it, matches a live registration, and
relays. Routing lives in the device, so the TLS edge in front is a dumb pipe.

### The wire protocol, briefly

Both the forwarded request and the returned response are **inlined** as flat
scalar keys, not nested sub-messages. A nested sub-message is turned into a
content-addressed *link* by the HTTP codec, and that link does not survive the hop
to another machine (`necessary_message_not_found`). Inlined scalars have no such
indirection — this is what makes redirects, content types, and large bodies work
across a real network. A `tunnel-mode: envelope` marker lets a capable provider
signal full-envelope support; a node falls back to a plain body against a provider
that cannot, so one node works against either.

## The public edge (TLS + reaching the internet)

HyperBEAM serves **cleartext** (`cowboy:start_clear`); it does not terminate
public HTTPS or issue certificates. So public exposure is handled *beside* the
node, which keeps a hardened appliance out of the cert business:

1. A **companion box on the LAN** runs Caddy (`Caddyfile` here) to terminate the
   `*.tunnel.<domain>` **wildcard** TLS and proxy cleartext to the node. A wildcard
   cert forces an ACME **DNS-01** challenge (HTTP-01 cannot issue wildcards), so
   Caddy needs API credentials for your DNS provider.
2. A **thin edge** puts public traffic onto that companion — a VPS `:443` forward,
   or a home public IP with a port-forward.

`deploy/DEPLOY-namecheap-vps.md` is a concrete, tested recipe (Namecheap DNS-01 +
Caddy). The long-term option that removes even the companion box is an `acme@1.0`
device that lets HyperBEAM serve public HTTPS itself.

## Pointing a node at a provider

Any node with the `tunnel@1.0` device can attach at runtime — no rebuild:

```sh
curl -X POST http://<node>:8734/~tunnel@1.0/connect \
  -H 'content-type: application/json' \
  -d '{"peer":"https://tunnel.example.com","workers":3}'
```

**Use 3+ workers** — a worker is consumed while it executes a request, so several
keep the tunnel continuously answerable; the provider also grace-queues requests
for a recently-registered address so a brief gap never surfaces to the caller. To
make it automatic, merge `config/tunnel-client.fragment.json`. The node's public
hostname is `base32(address)` (lowercase, unpadded) under the provider's domain;
a node with an ephemeral wallet gets a new hostname each restart.

## Verifying

- `test/stock_broker_proof.erl` — stock node + device + `on/request` config =
  broker; Host-routed public requests are byte-identical to direct.
- `test/merge_proof.erl` — same, with `on/request = [manifest@1.0, tunnel@1.0]`,
  proving the tunnel routes even when it is not the first request hook.
- `test/broker_driver.erl` — drives a live provider process end to end.

```
/~meta@1.0/info/address            MATCH
/                                  MATCH   (307 + Location preserved)
/~hyperbuddy@1.0/index             MATCH   (2,285 B text/html)
/~hyperbuddy@1.0/bundle.js         MATCH   (4,230,990 B text/javascript)
ALL MATCH
```

## Operational notes

- **Fault containment.** A request that cannot be forwarded fails only its own
  caller; the registration returns to the pool and the provider keeps serving
  every other node.
- **Observability.** `GET /~tunnel@1.0/status` (Accept: application/json) reports
  registered addresses, pending requests, and open registrations.
- **Exposure.** The provider does not authenticate registrations, so an open
  provider is an open relay for anyone who knows it. Allowlist node addresses in
  front of `/~tunnel@1.0/register`, or firewall it, if that is not what you want.

## Layout

```
src/dev_tunnel.erl                    tunnel@1.0 device: request hook, client, envelope
src/dev_tunnel_server.erl             provider state: registrations, dispatch, fault containment
config/README.md                      which keys to merge into a node config, with a bundler example
config/tunnel-provider.fragment.json  on/request hook + trusted-devices pin (merge in)
config/tunnel-client.fragment.json    on/start connect hook (merge in)
LAPEE.md                              device+config proof, LapEE topology, trust model
Caddyfile                             companion-box wildcard TLS (the edge)
deploy/DEPLOY-namecheap-vps.md        concrete edge recipe (Namecheap DNS-01 + Caddy)
test/stock_broker_proof.erl           proof: stock node + device + config = broker
test/merge_proof.erl                  proof: tunnel routes as a non-first on/request hook
test/broker_driver.erl                end-to-end parity check against a live provider
```
