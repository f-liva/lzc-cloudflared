#!/bin/sh
# lzc-cloudflared: run cloudflared with infinite retry.
#
# The stock store package (cloudfalredweb / wisdomsky-cloudflared-web) never
# restarts cloudflared after it exits. On the daily NAS boot (07:00) the box
# DNS is not ready yet, cloudflared dies on the argotunnel SRV lookup and the
# tunnel stays down until someone restarts the container by hand. This loop
# is the whole fix.
#
# Token source: TUNNEL_TOKEN env, else /config/config.json {"token": "..."}
# (same file layout the old package used, kept out of git).

# The box DNS loses the boot race. systemd-resolved on the NAS starts at
# 07:00:38 but is not answering yet when the Lazycat DNS proxy (172.18.0.1,
# upstream 127.0.0.53) and the containers come up ~25s later: every lookup in
# that window dies with "read udp 127.0.0.1->127.0.0.53:53: i/o timeout", so
# cloudflared cannot resolve region1.v2.argotunnel.com and exits. The retry
# loop below recovers in ~10s; appending a public resolver AFTER the box one
# closes even that gap, because a timeout (unlike NXDOMAIN) falls through to
# the next nameserver.
#
# Order matters and must not be flipped: the tunnel's own origins are
# *.lzcapp names that ONLY 172.18.0.1 knows (e.g.
# gitea.cloud.lazycat.app.gitea.lzcapp). A public resolver answers those with
# an authoritative NXDOMAIN, which does NOT fall through — putting 1.1.1.1
# first breaks every ingress rule with "no such host".
#
# The resolver on the NAS itself is not ours to fix: lzcos manages
# systemd-resolved without a unit file and /AGENTS.md forbids touching system
# config.
#
# DNS_FALLBACK="" disables the append; set it to other servers to change them.
DNS_FALLBACK="${DNS_FALLBACK-1.1.1.1 1.0.0.1}"
if [ -n "$DNS_FALLBACK" ] && [ -w /etc/resolv.conf ]; then
  for s in $DNS_FALLBACK; do
    grep -q "^nameserver[[:space:]]*$s\b" /etc/resolv.conf || echo "nameserver $s" >> /etc/resolv.conf
  done
  # Without this a dead box resolver burns 5s per attempt before falling through.
  grep -q "^options.*timeout:" /etc/resolv.conf || echo "options timeout:2 attempts:2" >> /etc/resolv.conf
  echo "[entrypoint] resolv.conf: $(tr "\n" " " < /etc/resolv.conf | tr -s " ")"
fi

PID=""
term() { [ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null; exit 0; }
trap term TERM INT

while true; do
  TOKEN="${TUNNEL_TOKEN:-$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /config/config.json 2>/dev/null)}"
  if [ -z "$TOKEN" ]; then
    echo "[entrypoint] no token (env TUNNEL_TOKEN or /config/config.json), retry in 10s"
    sleep 10
    continue
  fi

  # ha-connections 1 on purpose: behind a shared-IPv4 (MAP-E) line the ISP box
  # kills the long-lived edge connections, and with the default 4 the tunnel
  # reconnected ~1.6 times/min, so Cloudflare answered 502 in the gaps.
  # Measured 16/10/2026 on Iliad FTTH, per minute of reconnects:
  # http2+4 (default) 1.6, quic+4 2.6, http2+1 0.6, quic+1 0.13.
  cloudflared tunnel --no-autoupdate \
    --protocol "${PROTOCOL:-quic}" \
    --ha-connections "${HA_CONNECTIONS:-1}" \
    --metrics "${METRICS_ADDR:-0.0.0.0:36500}" \
    run --token "$TOKEN" &
  PID=$!
  wait "$PID"
  RC=$?
  PID=""
  echo "[entrypoint] cloudflared exited (rc=$RC), restart in 10s"
  sleep 10 &
  wait $!
done
