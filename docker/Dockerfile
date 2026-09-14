FROM cloudflare/cloudflared:2026.9.1 AS src

FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=src /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && cloudflared --version
ENTRYPOINT ["/entrypoint.sh"]
