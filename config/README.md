# Config fragments — merge these into your node config

These are **not** standalone config files. A HyperBEAM node — including a LapEE —
already boots from one main node config (for a LapEE bundler, that is the bundler
config). You turn a node into a tunnel provider, or a tunnel client, by **merging
a few keys into that existing config**, not by pointing it at a separate file.

This is the same overlay merge a LapEE/AndEE already performs for operator config
(`on` hooks are concatenated, `trusted-devices` maps are combined). The files here
document exactly which keys to add.

> Running the broker *outside* a LapEE (a bare `erl` process on a generic host)
> is the only case that uses a whole standalone file — see `../standalone/` and
> `../src/tunnel_broker.erl`. That path is not LapEE-native and exists only for
> convenience.

## `tunnel-provider.fragment.json` — make a node a broker

Adds one request hook. Merge its `on.request` entry into your config's `on.request`
list, and add the `tunnel@1.0` pin to your `trusted-devices`:

```jsonc
{
  "on": {
    "request": [ { "device": "tunnel@1.0", "path": "request" } ]
  },
  "trusted-devices": {
    "tunnel@1.0": "<published-tunnel-impl-id>"
  }
}
```

## `tunnel-client.fragment.json` — make a node publish itself

Adds one start hook that dials the broker on boot:

```jsonc
{
  "on": {
    "start": [
      { "device": "tunnel@1.0", "method": "POST", "path": "connect",
        "peer": "https://tunnel.example.com", "workers": 3,
        "hook": { "result": "ignore" } }
    ]
  }
}
```

## Worked example — adding the provider role to a bundler config

A LapEE bundler config already looks like this (abridged):

```jsonc
{
  "store": [ ... ],
  "on": {
    "start":   [ { "device": "...bundler bootstrap..." }, { "device": "measurement@1.0", ... } ],
    "request": [ { "device": "manifest@1.0" } ]
  },
  "trusted-devices": {
    "ao-payment@1.0": "7eAMY...",
    "pricing-router@1.0": "UH8LN...",
    ...
  },
  "trusted-device-signers": [ ... ]
}
```

To also serve as a tunnel provider, you merge — you do **not** replace or add a
second file:

```jsonc
{
  "store": [ ... ],
  "on": {
    "start":   [ { "device": "...bundler bootstrap..." }, { "device": "measurement@1.0", ... } ],
    "request": [
      { "device": "manifest@1.0" },
      { "device": "tunnel@1.0", "path": "request" }   // ← added
    ]
  },
  "trusted-devices": {
    "ao-payment@1.0": "7eAMY...",
    "pricing-router@1.0": "UH8LN...",
    "tunnel@1.0": "<published-tunnel-impl-id>"          // ← added
  },
  "trusted-device-signers": [ ... ]
}
```

The node is now a bundler **and** a tunnel provider — one config, one appliance.

> **Status:** the provider request-hook behavior itself is proven end to end
> (`../test/stock_broker_proof.erl`: stock node + `tunnel@1.0` + `on.request` hook
> = full-parity broker). Booting a LapEE from a real merged bundler config is the
> remaining seam to validate on hardware; the fragments above are the exact keys
> that merge in.
