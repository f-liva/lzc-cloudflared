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

This package drops the web UI entirely: official `cloudflared` binary + a
POSIX-sh entrypoint that restarts it forever with a 10s backoff
(`docker/entrypoint.sh`). A DNS hiccup at boot now costs at most ~10 seconds.

## Layout

- `docker/` — image `fliva/lzc-cloudflared` (multi-stage: binary from the
  distroless `cloudflare/cloudflared` image, dropped into Alpine +
  ca-certificates, entrypoint loop).
- `cloudflared-lzc/` — lpk sources (`package.yml`, `manifest.yml`, `icon.png`).
  The lpk is assembled by hand: `tar cf <pkg>.lpk icon.png manifest.yml package.yml`.

## Configuration

The tunnel token is **not** in this repo. The entrypoint reads, in order:

1. env `TUNNEL_TOKEN`
2. `/config/config.json` → `{"token": "..."}` — bind of
   `/lzcsys/data/appvar/cloud.lazycat.app.cloudflared/config/config.json`
   on the NAS (same file layout the old package used).

Other env knobs: `PROTOCOL` (default `http2`), `METRICS_ADDR`
(default `0.0.0.0:36500`; `/ready` on that port tells tunnel health).

## Release

```bash
cd docker/
docker build -t fliva/lzc-cloudflared:X.Y.Z .
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
