#!/bin/sh
# Cloudflare tunnel connector entrypoint. Picks the connector mode from whether a locally-managed config
# file is present, so a self-hoster gets a zero-config remotely-managed tunnel by default but can drop in a
# config.yml to take full local control (custom ingress, path routing, multiple services) without editing
# compose. See docs/OPERATIONS.md and config.yml.example.
set -e

CONFIG=/etc/cloudflared/config.yml

if [ -f "$CONFIG" ]; then
    echo "cloudflared: locally-managed tunnel (found $CONFIG)"
    exec cloudflared --no-autoupdate tunnel --config "$CONFIG" run
fi

if [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "cloudflared: no $CONFIG and CLOUDFLARE_TUNNEL_TOKEN is empty - nothing to run." >&2
    echo "  Set CLOUDFLARE_TUNNEL_TOKEN in .env for a dashboard-managed tunnel, OR copy" >&2
    echo "  cloudflared/config.yml.example to cloudflared/config.yml for a locally-managed one." >&2
    exit 1
fi

echo "cloudflared: remotely-managed tunnel (no $CONFIG; using CLOUDFLARE_TUNNEL_TOKEN)"
exec cloudflared --no-autoupdate tunnel run --token "$CLOUDFLARE_TUNNEL_TOKEN"
