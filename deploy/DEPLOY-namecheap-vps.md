# The public edge: wildcard TLS + reaching the internet (Namecheap recipe)

The **provider node** (an AndEE/LapEE, or any HyperBEAM node with `tunnel@1.0`)
runs the broker itself and serves **cleartext**. This document is only the *edge*
around it: a companion running Caddy that terminates wildcard TLS, plus the DNS
and firewall to put public traffic onto it. Nothing here runs a broker — the node
does that (see the repo README + `config/`).

Concrete values below are from the `tunnel.permaweb.space` bring-up on a Debian 13
box; adapt the domain, IP and node address.

## 0. Namecheap API

Enable API access (Profile → Tools → API Access) and **whitelist the public IP of
the box that runs Caddy** (the edge box). Namecheap checks the *source* IP of
every call, so the DNS-01 challenge only works from the whitelisted host. You
need: API user, API key, and that IP.

> Two topologies. **Simplest:** Caddy and the node on the same box (what the
> `tunnel.permaweb.space` bring-up did) — forward to `127.0.0.1:<node-port>`.
> **LapEE-native:** Caddy on a LAN companion / VPS edge, forwarding to a separate
> node; the edge must be able to reach the node's cleartext port (same LAN, or a
> VPN if the edge is a remote VPS). Whitelist whichever box runs Caddy.

## 1. DNS records (Namecheap API, BasicDNS)

`setHosts` REPLACES every record for the domain, so include everything you want
to keep. For a fresh domain, two A records:

    HostName=tunnel     RecordType=A  Address=<vps-ip>  TTL=300
    HostName=*.tunnel   RecordType=A  Address=<vps-ip>  TTL=300

Both the wildcard AND the bare `tunnel` are required: nodes register to the
apex peer `https://tunnel.<domain>`, and public traffic arrives at
`<b32>.tunnel.<domain>` — a wildcard cert/label does NOT cover the bare apex, so
you need both or the node's registration handshake fails with a TLS alert.

## 2. The provider node

The broker is your PermawebOS node — an AndEE/LapEE with the `tunnel@1.0` device
and the provider config merged in (see the repo README and `config/`). It serves
cleartext HTTP on its LAN address (e.g. `http://<node-lan-ip>:8734`). Caddy on the
companion box forwards to that address; point `reverse_proxy` at it below. There
is no separate broker process to run on the edge box.

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
        reverse_proxy http://<node-lan-ip>:8734 {
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
