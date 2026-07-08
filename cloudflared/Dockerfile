# Cloudflare tunnel connector with a mode-selecting entrypoint (remotely- vs locally-managed).
# The official cloudflared image is distroless (no shell), so the entrypoint can't branch on a config file.
# We copy its static binary onto a slim glibc base that has a shell + CA certs, and run our entrypoint.
FROM cloudflare/cloudflared:latest AS cf

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=cf /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh /usr/local/bin/tunnel-entrypoint.sh
RUN chmod +x /usr/local/bin/tunnel-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/tunnel-entrypoint.sh"]
