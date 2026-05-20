# AvNav ocharts Port Model

## Why this exists

On seabird (aarch64), direct client access to the ocharts backend on port 8083 can hang for non-local origins (including tailnet clients), even when the TCP handshake succeeds.

Observed behavior:

- `127.0.0.1:8083` responds quickly.
- `container-ip:8083` responds quickly.
- `tail-ip:8083` can connect but stall with no HTTP payload.

To keep AvNav charts working for browser clients that use `:8083`, the system fronts port 8083 with Caddy and forwards locally to an internal-only AvNav mapping.

## Port layout

- AvNav UI: `8088 -> 8080` (published by avnav container)
- ocharts backend internal host mapping: `28083 -> 8083` (published by avnav container)
- External ocharts endpoint for clients: `8083` (served by Caddy, reverse-proxy to `127.0.0.1:28083`)

## Where this is configured

- AvNav quadlet: `config/quadlets/avnav.container`
- Caddy config: `config/caddy/Caddyfile`
- Installer that deploys Caddy config: `scripts/install-firewall.sh`
- Full bootstrap summary output: `scripts/install-all.sh`

## Validation

Run on a workstation:

```bash
curl -sS -m 8 -o /dev/null -w 'avnav=%{http_code} total=%{time_total}s\n' http://100.64.0.1:8088/
curl -sS -m 8 -o /dev/null -w 'ocharts=%{http_code} total=%{time_total}s\n' http://100.64.0.1:8083/
```

Expected:

- AvNav (`8088`) returns `301` or `200`.
- Ocharts (`8083`) returns a fast HTTP response (often `404` at `/`, which is acceptable for reachability).

## Operational notes

- Do not rely on direct client access to the container-published ocharts backend.
- Keep Caddy responsible for external `:8083`.
- If testing with `avnav-test`, avoid reusing the same host-side ocharts port as production avnav.
