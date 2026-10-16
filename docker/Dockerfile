FROM cloudflare/cloudflared:2026.9.1 AS src

FROM alpine:3.22
# busybox-extras: httpd with CGI, for the config web UI. Nothing else added.
RUN apk add --no-cache ca-certificates busybox-extras
COPY --from=src /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh /entrypoint.sh
COPY www /www
RUN chmod +x /entrypoint.sh /www/cgi-bin/api && cloudflared --version && httpd --help 2>&1 | head -1
ENTRYPOINT ["/entrypoint.sh"]
