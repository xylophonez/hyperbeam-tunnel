# Running the tunnel provider inside a LapEE (device + config only)

A tunnel provider should not be a weaker trust link than the nodes it fronts. A
plain VPS with operator-custody keys is exactly the model
[LapEE](https://permawebos.arweave.net/run) exists to replace. So the intended
production shape is: run the broker itself as a LapEE — a hardened, attested
HyperBEAM appliance.

## The claim, and the proof

**A base LapEE + the `tunnel@1.0` custom device + a broker config is a complete
tunnel provider. No other code.**

This is proven by `test/stock_broker_proof.erl`: it starts a broker using the
*stock* `hb_http_server:start_node/1` — no custom launcher, no device seed —
given only

1. `tunnel@1.0` resolvable from the node's device package (its forge preloaded
   store), and
2. config: `on/request => tunnel@1.0/request`.

A second node registers, public traffic is routed by Host header alone, and the
relayed response is byte-identical to a direct request — for a 307 redirect, a
2.3 KB HTML page and a 4.2 MB JS bundle:

```
== stock broker parity (Host-routed public vs direct) ==
/~meta@1.0/info/address            MATCH
/                                  MATCH
/~hyperbuddy@1.0/index             MATCH
/~hyperbuddy@1.0/bundle.js         MATCH
ALL MATCH -- base node + tunnel device + config = broker
```

`src/tunnel_broker.erl` in this repo is only for running the broker *outside* a
LapEE (bare `erl` on a generic host). Inside a LapEE the appliance's own
bootstrap starts the node from config, so the launcher is unnecessary.

## What is device, what is config, what is neither

**Device** (`src/dev_tunnel.erl`, `src/dev_tunnel_server.erl` = `tunnel@1.0`):
all routing (Host `<b32>.<domain>` decoding lives *in* the device), registration,
dispatch, the inline request/response envelope, fault containment, and the client
side. Ships in the device package like the bundler device package.

**Config** (hotloadable): role selection is pure config —
`config/broker-role.json` (`on/request`) makes a node a broker;
`config/client-role.json` (`on/start` connect) makes a node publish itself. A
`trusted-devices` pin selects the implementation.

**Neither** (must live outside the LapEE): **public TLS termination + wildcard
certificate issuance.** HyperBEAM serves cleartext (`cowboy:start_clear`); it does
not terminate public HTTPS or run ACME. This is a general HyperBEAM edge concern,
not specific to tunnelling.

## Recommended topology — keep the LapEE pure, terminate TLS beside it

```
                              LAN
  public internet     ┌───────────────────────────────────────┐
        │             │                                        │
   ┌────┴─────┐   ┌───┴────────────┐        ┌──────────────────┴─┐
   │ edge:    │   │ companion box  │        │ LapEE               │
   │ VPS fwd  │──▶│ Caddy: wildcard│───────▶│ HyperBEAM broker    │
   │  OR home │   │ TLS terminate  │ cleartext  (tunnel@1.0       │
   │ public IP│   │ (*.tunnel.dom) │  :9080 │   + broker-role cfg)│
   └──────────┘   └────────────────┘        └──────────┬──────────┘
                                                        │ long-poll
                                            ┌───────────┴──────────┐
                                            │ client nodes (phones,│
                                            │ other LapEEs, …)     │
                                            └──────────────────────┘
```

- The **LapEE** runs only HyperBEAM (device + `broker-role.json`), cleartext on
  loopback/LAN. Nothing else installed on it. Its trust properties are intact.
- A **companion box on the LAN** attaches the wildcard-TLS front (the `Caddyfile`
  in this repo). It is not part of the LapEE trust boundary; it is the edge.
- Reaching the public internet is either a **thin VPS edge** that forwards
  `:443` to the companion, or a **home public IP** with a port-forward. Either
  way the trust-bearing work stays on the LapEE, and no general-purpose VPS holds
  keys or runs the appliance.

This keeps the whole thing inside the PermawebOS ecosystem: the broker is a
LapEE, the only non-node piece is TLS at the edge.

## Two remaining production items

1. **Publish `tunnel@1.0` to Arweave and pin the published ID** in
   `trusted-devices`. Base LapEE's trusted devices are all published Arweave IDs;
   a pin to a local forge archive falls through to name resolution (loads the
   right device, but is not a real content guarantee). Publishing makes the pin a
   true, verifiable selection — identical in kind to every other trusted device.

2. **Bring public TLS in-model** if you want to drop even the companion box: wire
   cowboy TLS (`start_tls`) with the wildcard cert as a node secret, and add an
   ACME device (`acme@1.0`) for issuance/renewal. That would let a single LapEE
   serve public HTTPS directly — useful well beyond tunnelling.

## Trust-minimised endgame (optional)

The strongest answer to "the provider must not be weaker than the node" is to
make the provider need *no* trust: route raw TLS by SNI (`<b32>.<domain>`) to the
node, which holds its own certificate and terminates TLS itself — the broker sees
only ciphertext. Then it does not matter whether the broker is a LapEE or a random
box. Cost: per-node certificates and a TCP/TLS-level tunnel (a redesign, not a
config change). The attested-LapEE relay above is the pragmatic near-term; this is
the north star.
