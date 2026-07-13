# Changes from v1

This is the second design of the HyperBEAM reverse tunnel. "v1" is the original
one that shipped only as `arch/android/scripts/andee-tunnel-smoke.sh` in the
AndEE/LapEE tree — a smoke test wired to a **third-party broker** you didn't
control, driving a published `tunnel@1.0` device with known wire bugs:

| v1 default | meaning |
| --- | --- |
| `TUNNEL_PEER=https://smoke.solutions` | broker run by someone else |
| `TUNNEL_IMPL=mfpw6oZe4NDaMMbkhulgQ63GcNHlwhOCRDTAQU5wjww` | original device, buggy across a machine hop |
| `REMOTE_TRUSTED_TUNNEL_IMPL=tF8WoGCaz…` | broker-side impl |
| driven by `adb forward` | validated over USB, never as a real roaming public URL |

The starting point was a device with a correctness bug, pointed at a broker you
didn't own, proven only by a local smoke script. This repo is the successor:
`tunnel@1.0` published as `u3K9cV05p14IZ_t0dWTptuu87J1NT-LhgirldS9SsVM`,
referenced from optional config, with a broker you can self-host.

## 1. The load-bearing correctness fix

v1 nested the relayed request and response as sub-messages. Across a machine hop
those become **content-addressed links the far node can't resolve** — the broker
failed with `necessary_message_not_found`. It worked on loopback and broke on the
open internet.

The fix inlines the request and response as **flat scalar keys**, gated by
explicit markers:

- `tunnel-mode: envelope` — broker → node
- `tunnel-response: envelope` — node → broker

This is the single change that turns the tunnel from "works locally, fails
across the internet" into something that actually round-trips. Most of the growth
in `dev_tunnel.erl` (1211 → 1698 lines) and `dev_tunnel_server.erl` (335 → 449)
is this fix and its fallout.

## 2. Full parity with un-tunneled HyperBEAM

The v1 third-party broker silently degraded the response:

- any **map response → HTTP 500**
- any **large body → HTTP 400**

The client is now dual-mode (envelope vs body-only) and the broker reconstructs
the response faithfully, giving **byte-for-byte parity** with hitting the node
directly — status codes, redirects, content types, and bodies of any size.
Verified for a 307 redirect (with `Location` preserved), a 2.3 KB page, and a
4.2 MB JS bundle. Hyperbuddy loads through the public URL identically to loading
it on the LAN.

## 3. A broker you own, not a third party

v1 depended on `smoke.solutions`. This repo adds a standalone `tunnel_broker`
plus the SERVE side of `dev_tunnel`, so the provider is **device + config on a
stock HyperBEAM node** (proven by `test/stock_broker_proof.erl`). It runs with:

- fault containment — a malformed `{as,…}` tuple can't crash the gen_server
- liveness-grace queueing for registrations
- request scrubbing before relay

The intended production shape is running the broker **as a LapEE** so the
provider is not a weaker trust link than the nodes it fronts (see
[`LAPEE.md`](LAPEE.md)). A reference deployment runs at `tunnel.permaweb.space`:
HyperBEAM serving cleartext, a Caddy companion box terminating wildcard TLS via
ACME DNS-01 (see [`Caddyfile`](Caddyfile) and
[`deploy/`](deploy/)).

## 4. Config-driven endpoint, device-as-published-ID

v1 effectively baked the endpoint into the build. The client now **inherits the
broker from JSON config** via the generic LapEE/AndEE config-loading pattern —
the node reads its peer and worker count from the `on/start tunnel@1.0` connect
hook; nothing is hardcoded (see
[`config/tunnel-client.fragment.json`](config/tunnel-client.fragment.json)).

The device itself is **never source in the base repo**. It is published to
Arweave (`u3K9cV05p14IZ_t0dWTptuu87J1NT-LhgirldS9SsVM`) and referenced only from
optional config as a trusted device. Custom devices live as IDs in optional
configs, not in base.

## 5. Runtime fixes that were blocking the tunnel from running at all

On the AndEE Android side, three defects kept the tunnel from ever starting:

- **Boot crash** ("bad runtime zip digest marker") — fixed the extraction-marker
  parse and version-binding.
- **Cleartext blocked** on `targetSdk 36` — a `network_security_config` now
  scopes cleartext to `127.0.0.1`/`localhost` only (the node talks to itself in
  the clear; TLS is terminated at the companion box).
- **Notification permission** — `POST_NOTIFICATIONS` is requested at runtime so
  the *Copy public URL* action shows on Android 13+.

## 6. Publishing

The device + broker are now this OSS repo, and the device is published to Arweave
with the ID pinned into the bundler config — uploaded as a direct ANS-104
dataitem to Turbo (zero L1 AR spent), working around the broken forge uploader in
the packaged HyperBEAM.

## Net effect

v1 was a USB smoke test against a broker you didn't own, running a device that
broke across a real network hop. This design is a self-hostable, LapEE-grade
tunnel with byte-identical parity, driven entirely by optional config pointing at
a published device ID — proven end-to-end on a real roaming phone, not just over
`adb forward`.
