# Fully Integrated Boat Server Plan (Refined, Decision-Complete)

## 0) Final Decisions

### Hardware and Interface Decisions
- Platform: Raspberry Pi CM4 Rev 1.0, 8GB RAM on custom carrier board
- OS model: **standard Fedora 44 aarch64 RPM** — services containerized via Quadlets, host OS is plain Fedora (not bootc)
- Storage split:
	- eMMC (16GB): OS, boot, container images (`/var/lib/containers`)
	- NVMe (1TB, btrfs): all service data, logs, backups
- **Actual enumerated interfaces:**
  - WAN (uplink, all used opportunistically):
    - `wwan0` — Foxconn T99W175 5G modem (PCIe, Qualcomm SDX55) ✅ working
    - `wlan0` — CM4 onboard BCM43455 WiFi (client/uplink mode)
    - `end0`  — CM4 onboard GbE
  - LAN (crew network):
    - `wlp6s0` — Intel PCIe WiFi (access point)
    - `enp4s0` — PCIe Realtek GbE (wired crew LAN)

### Modem Status (Foxconn T99W175 / Qualcomm SDX55 5G)
- **WORKING** — fix was `dtoverlay=pcie-32bit-dma` in `/boot/efi/config.txt`
- Root cause: BCM2711 PCIe inbound DMA window at `0x400000000`, unreachable by 32-bit DMA devices
- Firmware: `/lib/firmware/qcom/sdx55m/foxconn/prog_firehose_sdx55.mbn`
- ModemManager detects as `Snapdragon(TM) X55`, carrier config `Vodafone`
- See `docs/cellular-modem-setup.md` for full details

### Operations Decisions
- Primary usage: mixed (harbor + cruising)
- Network architecture: routed and NATed, firewalld with custom `wan`/`lan` zones
- Captive portal: auto-detected via NetworkManager, proxied through Caddy at `http://seabird.local/portal/`
- Logging: persistent journald on NVMe, 10GB cap, 1-month file rotation
- Backups: weekly local USB backup + monthly remote sync when dock connectivity allows
- GitOps model: scripts in repo drive all configuration; services updated via `podman auto-update`
- CM4 USB device workflow: `rpiboot` for provisioning/recovery

---

## 1) Phase 0 - Hardware Upbringing ✅ COMPLETE

### 1.1 Bring-Up Status
- ✅ CM4 boots Fedora 44 aarch64 from eMMC
- ✅ All PCIe devices enumerated: ASM1184e switch → Realtek NIC + T99W175 modem + Intel WiFi
- ✅ `pcie-32bit-dma` overlay applied — 5G modem working
- ✅ Deterministic interface naming confirmed (`end0`, `enp4s0`, `wlan0`, `wlp6s0`, `wwan0`)
- ✅ ModemManager detects T99W175 as 5G capable, SIM present

### 1.2 Fedora Host Packages (baseline — install via dnf)
```
linux-firmware NetworkManager firewalld caddy gdal
iw wpa_supplicant ethtool iproute
podman
libqmi libmbim ModemManager
btrfs-progs
```

---

## 2) Phase 1 - Host Storage and OS Layout

Goal: lock in durable storage and host lifecycle.

### 2.1 Filesystem Layout (btrfs on NVMe — `nvme0n1`)
All subvolumes mounted with `noatime,compress=zstd:1,space_cache=v2`

| Subvolume | Mount point | Purpose |
|-----------|-------------|---------|
| `@journal` | `/var/log/journal` | systemd-journald (10GB cap) |
| `@containers-storage` | `/var/lib/containers` | podman image storage (moved off eMMC) |
| `@containers-vol` | `/var/lib/containers/volumes` | podman volume data |
| `@data-signalk` | `/srv/seabird/signalk` | Signal-K data |
| `@data-influxdb` | `/srv/seabird/influxdb` | InfluxDB data |
| `@data-grafana` | `/srv/seabird/grafana` | Grafana data |
| `@data-nextcloud` | `/srv/seabird/nextcloud` | Nextcloud data |
| `@backup` | `/srv/seabird/backup` | local backups |
| `@snapshots` | (unmounted) | snapper target |

eMMC (unchanged): `/boot/efi` + `/boot` + LVM xfs root (OS only — container images on NVMe)

### 2.2 Install Script
`scripts/install-storage.sh [/dev/nvme0n1]` — formats, creates subvolumes, writes fstab, configures journald.

### 2.3 Snapshot and Backup Policy
- Daily local btrfs snapshots, retain 14
- Weekly consolidated backup to USB → `/srv/seabird/backup`
- Monthly off-boat sync when dock connectivity allows

---

## 3) Phase 2 - Network Topology and Routing

Goal: stable multi-WAN uplink + isolated onboard LAN.

### 3.1 Firewall (firewalld)
Two custom zones — `scripts/install-firewall.sh` deploys them:

| Zone | Interfaces | Policy |
|------|-----------|--------|
| `wan` | `wwan0`, `wlan0`, `end0` | DROP inbound, masquerade (NAT) |
| `lan` | `wlp6s0`, `enp4s0` | ACCEPT, ssh/dns/dhcp/mdns |

Forwarding policy `lan-to-wan`: allows crew LAN traffic to reach all WAN uplinks.
IP forwarding enabled via `/etc/sysctl.d/90-seabird-forward.conf`.

Config files: `config/firewalld/zones/wan.xml`, `config/firewalld/zones/lan.xml`

### 3.2 WAN Policy — Opportunistic Multi-WAN
All three WAN interfaces (`wwan0`, `wlan0`, `end0`) are used simultaneously.
ECMP routing via NetworkManager — all carry equal-metric default routes.
Per-interface routing tables (100/101/102) + connmark ensure return traffic
exits the same interface it arrived on.

### 3.3 Captive Portal Handling
NetworkManager detects portal state (`CONNECTIVITY_STATE=PORTAL`) automatically.

Flow:
1. NM detects captive portal on `wlan0`
2. Dispatcher (`config/nm-dispatcher/90-seabird-captive-portal`) generates a Caddy reverse proxy snippet
3. Portal becomes accessible at `http://seabird.local/portal/` (proxied via Caddy using `wlan0`'s IP)
4. Any crew browser can authenticate — NAT means all requests appear from `wlan0`'s IP
5. On `CONNECTIVITY_STATE=FULL` → snippet removed, Caddy reloads

Status written to `/run/seabird/captive-portal.json` for the Homepage dashboard banner.

### 3.4 DNS / LAN hostname
`seabird.local` resolves to the LAN IP via systemd-resolved + mDNS.

### 3.5 Security
- No admin services exposed on WAN zone
- VPN or SSH bastion required for remote admin

---

## 4) Phase 3 - GitOps Delivery

Goal: all configuration is in git; services updated via `podman auto-update`.

### 4.1 Model
- Host OS: standard Fedora 44 — updated via `dnf` on a schedule
- Services: OCI images pulled from public registries, `AutoUpdate=registry` in quadlets
- Config: this repo — install scripts apply config to the running host
- No bootc, no custom OS image builds

### 4.2 Install Scripts (in `scripts/`)
| Script | Purpose |
|--------|---------|
| `install-storage.sh` | Format NVMe, create btrfs subvolumes, write fstab |
| `install-firewall.sh` | Deploy firewalld zones, captive portal dispatcher, Caddy |
| `install-services.sh` | Deploy quadlets, weather updater/API scripts, AvNav weather panel (`user.js`), create data dirs, write env stubs |

### 4.3 Update Strategy
- `systemctl enable podman-auto-update.timer` — daily pulls new image digests
- Host packages: `dnf upgrade` in a maintenance window
- Config changes: pull repo, re-run relevant install script

---

## 5) Phase 4 - Service Stack (Quadlets)

Goal: deploy marine data and collaboration stack with clear dependencies.

### 5.1 Services

| Service | Port | Quadlet | Data path |
|---------|------|---------|-----------|
| Caddy | 80 | `caddy.container` | `/etc/caddy/` (config), `/run/seabird/` (portal status) |
| Signal-K | 3000 | `signalk.container` | `/srv/seabird/signalk` |
| InfluxDB | 8086 | `influxdb.container` | `/srv/seabird/influxdb` |
| Grafana | 3001 | `grafana.container` | `/srv/seabird/grafana` |
| Nextcloud | 8080 | `nextcloud.pod` (+ db, redis, cron) | `/srv/seabird/nextcloud` |
| Homepage | 3002 | `homepage.container` | `/srv/seabird/homepage` |

Quadlet files in `config/quadlets/`. Deployed by `scripts/install-services.sh`.

Signal-K routing note: `/signalk` on Caddy is kept for discovery/API paths, but the admin UI is redirected to `http://<host>:3000/admin/`. This avoids collisions with other root-level paths on `:80` (notably `/plugins/*` used by AvNav) and keeps Signal-K plugin/webapp management functional.

### 5.2 Data Flow
1. ESP32 reads NMEA2000 and emits UDP stream
2. Signal-K ingests UDP stream
3. Signal-K → InfluxDB via plugin
4. Grafana reads InfluxDB for dashboards
5. Weather model data is fetched on schedule and converted to MBTiles overlays for AvNav: ICON-D2 for atmospheric layers, DMI WAM for waves, and DMI DKSS for currents (with EWAM/CMEMS fallback paths) via `seabird-avnav-grib-update.timer` + `seabird-update-avnav-grib-overlay`.

### 5.5 Weather Overlay Pipeline (GRIB → MBTiles)

**Script:** `scripts/update-avnav-grib-overlay.sh`  
**Deployed to:** `/usr/local/sbin/seabird-update-avnav-grib-overlay`  
**Triggered by:** `seabird-avnav-grib-update.timer` (systemd)  
**Config:** `/etc/seabird/avnav-grib.env` (env file, not edited manually)

#### Data sources
| Layer | Source | Variable |
|-------|--------|---------|
| `wind_style` | DWD ICON-D2 | U/V 10m wind → colour scale + barbs |
| `wave_style` | DMI WAM (primary), DWD EWAM (fallback) | significant wave height + mean wave direction arrows |
| `current_style` | DMI DKSS (primary), CMEMS (fallback) | surface current arrows (U/V) |
| `temperature_2m` | DWD ICON-D2 | optional 2m temperature |
| `precipitation_total` | DWD ICON-D2 | optional total precipitation |
| `pressure_msl` | DWD ICON-D2 | optional mean sea-level pressure |

Rendering now runs in 1-hour steps for +1h to +48h by default and publishes each hour incrementally so AvNav can use freshly completed layers before the full cycle ends.

#### Wind overlay detail (`wind_style`)
Produces two MBTiles:
- `weather-wind-speed-kts.mbtiles` — colour-coded wind speed
  - Dark blue: < 6 kt, green: 6–16 kt, orange: ~25 kt, red: ≥ 30 kt (via `gdal_calc.py` + `gdaldem color-relief`)
- `weather-wind-barbs.mbtiles` — wind barb symbols rendered with matplotlib onto transparent tiles

#### AvNav integration
- All MBTiles must live at the **top level** of `/srv/seabird/avnav/charts/` — AvNav's chart scanner is non-recursive
- Naming convention: `weather-<name>.mbtiles` (controlled by `WEATHER_PREFIX=weather-` env)
- After generation the script restarts `avnav.service` to trigger re-index

#### Host dependencies (required; installed by `scripts/bootstrap.sh`)
```
gdal  gdal-python-tools  python3-gdal  python3-numpy  python3-matplotlib
```
Note: `gdal_calc.py` is provided by `gdal-python-tools`, **not** `python3-gdal`.

#### Key env vars (tunable in `/etc/seabird/avnav-grib.env`)
| Variable | Default | Notes |
|----------|---------|-------|
| `LAYERS` | `wind_style,wave_style,current_style` | comma-separated |
| `FORECAST_HOURS` | `001..048` | 1-hourly forecast steps (48h horizon) |
| `MINZOOM` | `9` | effective min zoom in produced MBTiles |
| `MAXZOOM` | `12` | effective max zoom |
| `ZOOM_MIN_LIMIT` | `6` | safety floor — MINZOOM is clamped up to this |
| `ZOOM_MAX_LIMIT` | `12` | safety ceiling — MAXZOOM is clamped down to this |
| `OVERZOOM_MAX_EXTRA_LEVELS` | `4` | if native tiles are lower-res, synthesise up to N extra zoom levels by tile-splitting |
| `LAYER_PARALLEL_WORKERS` | `auto` | per-hour layer fan-out; auto-sized by CPU and available memory |
| `WIND_BARB_WORKERS` | `3` | zoom-level workers for wind/wave/current symbol rendering |
| `WIND_BARB_STEP` | `24` | source-pixel spacing between barb symbols |
| `WIND_BARB_RENDER_SCALE` | `8` | render resolution multiplier for barb raster (higher = crisper) |
| `BBOX` | `8.0,53.0,16.5,60.0` | lon_min,lat_min,lon_max,lat_max (German Baltic) |

#### Lessons learned / gotchas
- AvNav MBTiles metadata `minzoom`/`maxzoom` must match the actual tile pyramid; the script rewrites both after tile generation
- The barb raster is rendered at `WIND_BARB_RENDER_SCALE × 100 dpi` then sliced into MBTiles; a scale of 3 fits comfortably on the constrained root filesystem (91% used); higher scales cause SQLite I/O errors if `/` fills
- The root filesystem (`/dev/mapper/systemVG-LVRoot`, ~13 GB) is at 91% usage — large temporary rasters write to `/var/tmp` (on NVMe) but intermediate GDAL outputs and MBTiles temp files also touch `/`; keep `WIND_BARB_RENDER_SCALE` ≤ 4 until the root volume is expanded
- Prior OOM incidents on Pi CM4 were mitigated by bounded layer concurrency and strip-based symbol rendering; do not raise `LAYER_PARALLEL_WORKERS` aggressively without checking memory headroom.

### 5.3 Start Order
```
NVMe mounts → caddy → influxdb → signalk → grafana → nextcloud-pod → homepage
```

### 5.4 Secrets
Stored in `/etc/seabird/*.env` (mode 0600), referenced via `EnvironmentFile=` in quadlets.
Example stubs written by `install-services.sh`.

---

## 6) Validation and Go-Live

### 6.1 Test Matrix
- Cold boot reliability (10+ cycles)
- Multi-WAN simultaneous operation
- Captive portal detection and proxy flow
- 24h service uptime under synthetic data load
- Backup and restore drill

### 6.2 Go-Live Criteria
- No critical kernel/network errors in 72h soak
- All dashboards populated from live ESP32 feed
- Recovery runbook validated (reboot, link loss, restore)

---

## 7) Implementation Sequence

1. ✅ Hardware bring-up — all interfaces working
2. ✅ 5G modem — working (`dtoverlay=pcie-32bit-dma`)
3. ✅ Firewall config — `scripts/install-firewall.sh`
4. ✅ Captive portal — NM dispatcher + Caddy proxy
5. ✅ Storage layout — `scripts/install-storage.sh`
6. ✅ Service quadlets — `scripts/install-services.sh`
7. ⬜ Multi-WAN routing tables — `scripts/install-routing.sh` (pending)
8. ⬜ wlan0 AP mode config for crew LAN
9. ⬜ Signal-K initial vessel configuration
10. ⬜ InfluxDB + Grafana dashboard setup
11. ⬜ Soak tests and failover validation
