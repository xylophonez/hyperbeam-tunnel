# Deploying on a VPS with a Namecheap domain (real recipe)

This is the exact path used to stand up `tunnel.permaweb.space` on a Debian 13
Vultr box. It uses Docker for both the broker and Caddy so nothing but Docker is
installed on the host.

## 0. Namecheap API

Enable API access (Profile → Tools → API Access) and **whitelist the VPS public
IP**. Namecheap checks the *source* IP of every call, so the API only works from
the whitelisted host — run Caddy (which drives the DNS-01 challenge) on that
same VPS. You need: API user, API key, and the whitelisted IP.

## 1. DNS records (Namecheap API, BasicDNS)

`setHosts` REPLACES every record for the domain, so include everything you want
to keep. For a fresh domain, two A records:

    HostName=tunnel     RecordType=A  Address=<vps-ip>  TTL=300
    HostName=*.tunnel   RecordType=A  Address=<vps-ip>  TTL=300

Both the wildcard AND the bare `tunnel` are required: nodes register to the
apex peer `https://tunnel.<domain>`, and public traffic arrives at
`<b32>.tunnel.<domain>` — a wildcard cert/label does NOT cover the bare apex, so
you need both or the node's registration handshake fails with a TLS alert.

## 2. Broker

Ship the HyperBEAM runtime (BEAM libs + NIFs + preloaded store) and the three
compiled broker beams (`dev_tunnel`, `dev_tunnel_server`, `tunnel_broker`).
**BEAM bytecode is architecture-independent** — compile once (e.g. in the
erlang:28.5 container) and copy the .beam files; only the NIF `.so`s are native,
and those come from a Linux/glibc build (NOT the Android runtime in an APK).

Run it under Docker with the preloaded store wired in:

    docker run -d --name tunnel-broker --network host \
      -v /opt/tunnel-broker:/opt/tunnel-broker -w /opt/tunnel-broker \
      -e HB_PRELOADED_STORE=/opt/tunnel-broker/runtime/store/preloaded-store \
      -e HB_PRELOADED_DEVICES_INDEX=<index-id> \
      erlang:28.5 erl -noshell \
        $(for d in runtime/lib/*/ebin; do printf -- '-pa /opt/tunnel-broker/%s ' $d; done) \
        -pa /opt/tunnel-broker/ebin \
        -eval 'tunnel_broker:start(<<"standalone/broker.json">>), receive stop -> ok end.'

`deploy/tunnel-broker.service` wraps this as systemd. The broker listens on
`127.0.0.1:9080` (or your configured port); keep it on loopback and let Caddy
face the internet.

## 3. Caddy with the Namecheap DNS plugin

Stock Caddy has no Namecheap module — build one:

    docker build -t caddy-namecheap - <<'DOCKER'
    FROM caddy:2-builder AS builder
    RUN xcaddy build --with github.com/caddy-dns/namecheap
    FROM caddy:2
    COPY --from=builder /usr/bin/caddy /usr/bin/caddy
    DOCKER

Caddyfile (cover apex AND wildcard in ONE block so both get the SAN):

    tunnel.example.com, *.tunnel.example.com {
        tls {
            dns namecheap {
                api_key   <key>
                user      <api-user>
                client_ip <vps-ip>     # the whitelisted IP
            }
            resolvers 1.1.1.1
        }
        reverse_proxy 127.0.0.1:9080 {
            flush_interval -1          # stream bodies, don't buffer
            transport http { read_timeout 120s  write_timeout 120s  dial_timeout 5s }
        }
    }

    docker run -d --name caddy --network host --restart unless-stopped \
      -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
      -v /opt/caddy/data:/data -v /opt/caddy/config:/config \
      caddy-namecheap

Caddy obtains a wildcard cert via a DNS-01 TXT challenge (no inbound needed for
issuance). Note the libdns namecheap provider reads existing records and appends
the TXT, so your A records survive — verify afterward regardless.

## 4. Firewall

Issuance is DNS-01, but **serving needs 80+443 inbound**. On a UFW default-DROP
box (common on VPS images) you must open them or every external request hangs:

    ufw allow 80/tcp && ufw allow 443/tcp && ufw reload

## 5. Point a node at it

    curl -X POST http://<node>:8734/~tunnel@1.0/connect \
      -H 'content-type: application/json' \
      -d '{"peer":"https://tunnel.example.com","workers":3}'

The node's public URL is `https://<base32(address)>.tunnel.example.com/`.

## Security reminders

- The broker does not authenticate registrations. Anyone who can POST
  `/~tunnel@1.0/register` can publish a node at its address's hostname. Firewall
  or allowlist that endpoint if the broker isn't meant to be open.
- Keep the Namecheap API key off the box if you can (Caddy supports
  `{env.NAMECHEAP_API_KEY}` + an EnvironmentFile on the systemd unit). The key
  can edit ALL DNS for the account.
