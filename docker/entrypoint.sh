#!/bin/sh
# lzc-cloudflared: run cloudflared with infinite retry.
#
# The stock store package (cloudfalredweb / wisdomsky-cloudflared-web) never
# restarts cloudflared after it exits. On the daily NAS boot (07:00) the box
# DNS is not ready yet, cloudflared dies on the argotunnel SRV lookup and the
# tunnel stays down until someone restarts the container by hand. This loop
# is the whole fix.
#
# Settings live in /config/config.json, written by the web UI (www/cgi-bin/api):
#   {"token","protocol","ha_connections","dns_fallback"}
# Env vars are the fallback for every key, so a manifest-only install (or the
# old config.json with just the token) keeps working unchanged. One source of
# truth means the UI and this loop can never show different values.

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
CONF=/config/config.json
cfg() { # cfg <key> -> value from config.json, empty if absent
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" 2>/dev/null | head -1
}

DNS=$(cfg dns_fallback)
[ -z "$DNS" ] && DNS="${DNS_FALLBACK-1.1.1.1 1.0.0.1}"
if [ -n "$DNS" ] && [ -w /etc/resolv.conf ]; then
  for s in $DNS; do
    grep -q "^nameserver[[:space:]]*$s\b" /etc/resolv.conf || echo "nameserver $s" >> /etc/resolv.conf
  done
  # Without this a dead box resolver burns 5s per attempt before falling through.
  grep -q "^options.*timeout:" /etc/resolv.conf || echo "options timeout:2 attempts:2" >> /etc/resolv.conf
  echo "[entrypoint] resolv.conf: $(tr "\n" " " < /etc/resolv.conf | tr -s " ")"
fi

# Web UI (busybox httpd + CGI). Port 36500 is what the lzc manifest routes to.
# It serves the config API, so it must stay up even while cloudflared is down:
# that is exactly when you need the panel to paste a token.
WWW_PORT="${WWW_PORT:-36500}"
if [ "${WWW_ENABLE:-1}" = 1 ]; then
  httpd -p "0.0.0.0:$WWW_PORT" -h /www
  echo "[entrypoint] web UI on :$WWW_PORT"
fi

PID=""
term() { [ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null; exit 0; }
trap term TERM INT

while true; do
  TOKEN="${TUNNEL_TOKEN:-$(cfg token)}"
  if [ -z "$TOKEN" ]; then
    echo "[entrypoint] no token yet (web UI, TUNNEL_TOKEN or /config/config.json), retry in 10s"
    sleep 10
    continue
  fi

  PROTO=$(cfg protocol); [ -z "$PROTO" ] && PROTO="${PROTOCOL:-quic}"
  HA=$(cfg ha_connections); [ -z "$HA" ] && HA="${HA_CONNECTIONS:-1}"

  # ha-connections 1 on purpose: behind a shared-IPv4 (MAP-E) line the ISP box
  # kills the long-lived edge connections, and with the default 4 the tunnel
  # reconnected ~1.6 times/min, so Cloudflare answered 502 in the gaps.
  # Measured 16/10/2026 on Iliad FTTH, per minute of reconnects:
  # http2+4 (default) 1.6, quic+4 2.6, http2+1 0.6, quic+1 0.13.
  echo "[entrypoint] starting cloudflared (protocol=$PROTO ha-connections=$HA)"
  # Metrics on 36501: 36500 is the web UI. The log also goes to a file the UI
  # reads to count reconnects (no docker-logs access from inside). Truncated
  # here so the count always refers to the run that is currently up — and no
  # pipe, or $! would be the pipe's tail and the TERM trap would miss.
  : > /tmp/cf-status
  cloudflared tunnel --no-autoupdate \
    --protocol "$PROTO" \
    --ha-connections "$HA" \
    --metrics "${METRICS_ADDR:-0.0.0.0:36501}" \
    run --token "$TOKEN" >> /tmp/cf-status 2>&1 &
  PID=$!
  wait "$PID"
  RC=$?
  PID=""
  echo "[entrypoint] cloudflared exited (rc=$RC), restart in 10s"
  sleep 10 &
  wait $!
done
