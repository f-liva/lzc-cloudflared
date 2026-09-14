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

  cloudflared tunnel --no-autoupdate \
    --protocol "${PROTOCOL:-http2}" \
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
