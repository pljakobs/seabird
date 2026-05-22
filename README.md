# seabird

**seabird** is a self-contained boat router and server running on a Raspberry Pi CM4. It bundles navigation tools, entertainment services, and system administration into a single Fedora [bootc](https://containers.github.io/bootc/) image that boots directly from eMMC and manages all services as rootless Podman containers via systemd quadlets.

The landing page (served by Caddy on port 80) links to all services. All services are reachable via sub-paths on the same host, so links work whether you connect over the LAN (`seabird.local`), Tailscale, or any other hostname.

---

## Hardware

The current implementation of seabird is based on a Raspberry Pi CM4 and the [CM4-WRT-A Router Baseboard](https://mytechcatalog.com/blog/2023/cm4-wrt-a-raspberry-pi-cm4-gigabit-router-baseboard-with-nvme-support).
This hardware has been chosen as it provides three PCIe m.2 slots that hold 
- an extra wifi interface
- a 5G modem 
- an NVMe

Modem: the current version uses the T99W175 Modem which is probably not the best choice as it is know for being difficult on current Linux systems. Seabird makes a couple of adaptations to enable this modem, but I might have to make a different choice in the future.
Changes for the T99W175:
- enable 32Bit DMA by loading the correct overlay
- disabling power management for the modem 

The three m.2 slots share one PCIe 2 lane, so performance is relative, but good enough for the given application.

## Networking

seabird is the boat's router. It has multiple network interfaces and manages connectivity for the crew LAN, WAN uplinks, and remote access.

### WiFi access point
`scripts/install-ap.sh` configures `wlp6s0` as a WPA2 access point using NetworkManager `ipv4.method=shared`. NM's built-in dnsmasq instance handles DHCP and DNS for crew devices on the AP. The SSID, passphrase, IP range, and band (2.4 / 5 GHz) are configurable.

### Wired crew LAN
`scripts/install-crew-lan.sh` configures a wired crew port (default: `end0`, the USB-attached ethernet adapter) in NM shared mode, also with DHCP/DNS via dnsmasq. The onboard ethernet (`enp4s0`) is kept free for WAN use.

### Firewall
`scripts/install-firewall.sh` sets up firewalld with two zones:

| Zone | Interfaces | Policy |
|------|-----------|--------|
| `lan` | `wlp6s0`, `enp4s0` | ACCEPT — crew clients |
| `wan` | `wwan0`, `wlan0`, `end0` | DROP inbound, masquerade |

A `lan-to-wan` policy allows crew clients to reach all WAN uplinks. A `--mode=dev` flag moves `end0` into the LAN zone for development use.

### WAN uplinks
The CM4 carrier board exposes a cellular modem (`wwan0`) via USB. `scripts/install-ap.sh` and NetworkManager handle fallback between cellular, marina WiFi (`wlan0`), and wired ethernet (`enp4s0`). The NM dispatcher scripts in `config/nm-dispatcher/` detect captive portals and write a status JSON to `/run/seabird/` for the Caddy landing page.

### Remote access — Tailscale / Headscale
`scripts/install-headscale.sh` installs Tailscale and optionally joins a Headscale control server. Once joined, the router is reachable at its Tailscale IP (currently `100.64.0.1`) from anywhere on the tailnet, enabling remote monitoring and administration without opening ports on the WAN firewall.

---

## Marine

### Signal-K — `/signalk`
Central marine data hub. Aggregates NMEA 0183 / NMEA 2000 instrument data (GPS, AIS, wind, depth, engine) and exposes it over the Signal-K WebSocket/REST API for other services and apps to consume.

### AvNav — `/avnav`
Chart plotter and navigation interface. Runs [AvNav](https://github.com/wellenvogel/avnav) on port 8088 (proxied from `/avnav`). AvNav reads live position and instrument data from Signal-K and renders raster and vector charts in the browser.

### Ocharts — `/ocharts` (also `:8083`)
Encrypted vector chart server. [oexserverd](https://www.o-charts.org/) handles licensed SENC charts and serves tiles to AvNav over an internal HTTP API on port 8083. A custom Caddy build ([`config/caddy/Containerfile.xcaddy`](config/caddy/Containerfile.xcaddy)) with the [`replace-response`](https://github.com/caddyserver/replace-response) plugin rewrites the container-internal `10.88.x.x` IP addresses that the backend bakes into `avnav.xml` and tile URLs with the public host seen by the browser.

---

## Data

### InfluxDB — `/influxdb`
Time-series database. Stores instrument data (wind, speed, heading, engine metrics, …) forwarded from Signal-K. Provides the data source for Grafana dashboards.

### Grafana — `/grafana`
Dashboard and visualisation. Displays time-series data from InfluxDB. Served with `GF_SERVER_SERVE_FROM_SUB_PATH=true` so it works correctly under `/grafana`.

---

## Entertainment

### Navidrome — `/navidrome`
Music streaming server. Serves the crew's music library over the [Subsonic API](https://www.subsonic.org/pages/api.jsp), compatible with any Subsonic client. Served with `ND_BASEURL=/navidrome`.

### Nextcloud — `/nextcloud`
File sync and crew collaboration. Runs as a Podman pod (`nextcloud.pod`) with a MariaDB database container and a Redis cache container. Requires `overwritewebroot=/nextcloud` in `config.php` to work under the sub-path.

---

## System

### Pi-hole — `/pihole`
DNS server and ad blocker for the boat LAN. Handles DHCP and DNS for all connected devices; blocks ad and tracker domains.

### Caddy — `/`
Landing page and reverse proxy. Routes all sub-path requests to the appropriate backend container. The `:8083` listener handles ocharts traffic with CORS headers and response-body rewriting. The custom image (`ghcr.io/pljakobs/caddy-xcaddy`) is built automatically by the [GitHub Actions workflow](.github/workflows/build-caddy.yml) whenever [`Containerfile.xcaddy`](config/caddy/Containerfile.xcaddy) changes.

### Cockpit — `/cockpit`
Web-based system administration. Provides a terminal, service management, and resource monitoring. Requires `UrlRoot=/cockpit` in `/etc/cockpit/cockpit.conf`.

---

## Repository layout

```
config/
  caddy/          Caddyfile, Containerfile.xcaddy (custom Caddy with replace-response)
  homepage/       Homepage dashboard config (services.yaml, bookmarks.yaml, …)
  quadlets/       Systemd quadlet .container / .pod files for all services
  avahi/          mDNS service announcements
  nm-dispatcher/  NetworkManager dispatcher scripts (captive portal, DNS)
  systemd/        Additional systemd unit overrides
  tmpfiles.d/     tmpfiles.d entries for runtime directories
scripts/
  install-*.sh    Component install scripts (run on the target device)
  bootstrap.sh    First-boot bootstrap
docs/
  cellular-modem-setup.md
.github/
  workflows/
    build-caddy.yml   Build and push ghcr.io/pljakobs/caddy-xcaddy on Containerfile change
```

## Image build

The bootc OS image is built with the artifacts pipeline defined in `artifacts/`. The raw eMMC image is written via `scripts/flash-emmc.sh` (in the freebird workspace).

## Deployment

Services are installed onto a running seabird device by running the install scripts in `scripts/`:

```bash
ssh root@seabird.local 'bash -s' < scripts/install-services.sh
```

Individual component scripts can be re-run to update a single service.

