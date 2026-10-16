# lzc-cloudflared

Minimal Cloudflare Tunnel connector for the Lazycat NAS (chronos box), packaged
as an `.lpk`. Replaces the store package `cloud.lazycat.app.cloudfalredweb`
(wisdomsky/cloudflared-web) on 2026-09-14.

## Why it exists

The chronos NAS powers off every night (02:00 → 07:00, Lazycat power schedule).
On every boot the store package raced the box DNS: `cloudflared` died once on
the `region1.v2.argotunnel.com` SRV lookup ("no such host") and its Node
wrapper **never restarted it** — the `close` handler in `cloudflare-tunnel.js`
just logs "Stopped cloudflared". Result: container "Up", tunnel dead,
Cloudflare answering **530 / error 1033** for every exposed hostname
(immich.federicoliva.it & co.) until someone restarted the container by hand.
Every single morning.

This package keeps the official `cloudflared` binary and wraps it in a
POSIX-sh entrypoint that restarts it forever with a 10s backoff
(`docker/entrypoint.sh`). A DNS hiccup at boot now costs at most ~10 seconds.

Since 1.1.0 it ships a small config panel of its own (busybox httpd + one CGI
script, `docker/www/`): tunnel token, protocol, edge connections and fallback
resolvers, plus live state — running, active connections, reconnects per
minute, uptime, version. The panel serves the config API, so it stays up while
cloudflared is down: that is exactly when you need it to paste a token.

## Layout

- `docker/` — image `fliva/lzc-cloudflared` (multi-stage: binary from the
  distroless `cloudflare/cloudflared` image, dropped into Alpine +
  ca-certificates, entrypoint loop).
  - `docker/www/` — the config panel: `index.html` (no framework, no CDN) and
    `cgi-bin/api` (`?a=status` / `POST ?a=save`).
  - `docker/test-api.sh` — self-check of the API against a running container:
    `docker run -d --name cftest -p 38500:36500 <image> && sh docker/test-api.sh`.
    Covers the validation branches, the settings round-trip and the
    keep-stored-token path. Run it before any release.
- `cloudflared-lzc/` — lpk sources (`package.yml`, `manifest.yml`, `icon.png`).
  The lpk is assembled by hand: `tar cf <pkg>.lpk icon.png manifest.yml package.yml`.

## Configuration

The tunnel token is **not** in this repo. Normal path: open the app on the NAS
and fill the panel. It writes `/config/config.json` (mode 600) — bind of
`/lzcsys/data/appvar/cloud.lazycat.app.cloudflared/config/` on the box — then
kills `cloudflared`, which the entrypoint loop restarts with the new settings.
Saving with an empty token field keeps the stored one.

`config.json` is the single source of truth; env vars are the fallback for each
key, so a manifest-only install (or an old file carrying just the token) keeps
working unchanged:

| key in config.json | env fallback | default |
| --- | --- | --- |
| `token` | `TUNNEL_TOKEN` | — (tunnel waits) |
| `protocol` | `PROTOCOL` | `quic` |
| `ha_connections` | `HA_CONNECTIONS` | `1` |
| `dns_fallback` | `DNS_FALLBACK` | `1.1.1.1 1.0.0.1` |

**Why 1 connection and quic.** On a shared-IPv4 line (MAP-E — Iliad FTTH here)
the ISP box kills long-lived edge connections, so cloudflared's default of 4
meant a reconnect every ~37s and Cloudflare answering **502** in the gaps.
Measured 2026-10-16 on that line, reconnects per minute:

| protocol | connections | reconnects/min |
| --- | --- | --- |
| http2 | 4 (upstream default) | 1.6 |
| quic | 4 | 2.6 |
| http2 | 1 | 0.6 |
| **quic** | **1** | **0.13** |

If the 502s come back, compare reconnects against uptime (the panel shows the
rate): above ~1/min the box is killing even the single connection, and the next
lever is a longer keepalive, not more connections.

Ports: `36500` panel + API (what the lpk routes to), `36501` cloudflared
metrics (`/ready`, `/metrics`). `WWW_ENABLE=0` disables the panel.

## Release

```bash
cd docker/
docker build -t fliva/lzc-cloudflared:X.Y.Z .
docker rm -f cftest; docker run -d --name cftest -p 38500:36500 fliva/lzc-cloudflared:X.Y.Z
sh test-api.sh   # must print ALL PASS
docker rm -f cftest
docker push fliva/lzc-cloudflared:X.Y.Z
# bump image tag in cloudflared-lzc/manifest.yml + version in package.yml
cd ../cloudflared-lzc/
tar cf cloud.lazycat.app.cloudflared-vX.Y.Z.lpk icon.png manifest.yml package.yml
scp *.lpk root@192.168.8.115:/tmp/ && ssh root@192.168.8.115 lpk-manager install /tmp/<lpk>
```

## Health check

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://immich.federicoliva.it/api/server/ping
# 200 = tunnel up; 530 = tunnel down
```

## License

MIT (wrapper). `cloudflared` is © Cloudflare, Apache-2.0.
