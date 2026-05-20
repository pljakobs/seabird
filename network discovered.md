this is the current setup, cle
Network Architecture — seabird
Internet uplink
LTE only via wwan0 (100.102.68.22/30). Default route → 100.102.68.21. IPv6 public address also present. The wired ports (end0, enp4s0) and wlan1 are all down/no-carrier — LTE is the sole internet path.

IP forwarding is enabled (required for NAT/routing).

Firewall — two-layer setup
nftables (firewalld) is the main firewall, with named zones:

Zone	Interface(s)
trusted	podman0 (container net), loopback traffic from 10.88.0.0/16
headnet	tailscale0
lan	wlp6s0 (WiFi AP → crew)
wan	wwan0, end0
FedoraServer	catch-all default
NAT masquerade is applied outbound on both wwan0 and end0. The lan-to-wan policy applies when traffic crosses from wlp6s0 → end0 or wlp6s0 → wwan0.

iptables (Tailscale-managed layer on top):

ts-input: accepts Tailscale traffic on port 41641/udp; blocks 100.64.0.0/10 arriving on non-Tailscale interfaces (anti-spoofing)
ts-forward: marks Tailscale-originated forwarded traffic, masquerades it on exit
Container isolation: explicitly DROP all forwarding from wwan0, wlan0, end0 → podman0 (containers cannot be reached directly from WAN or other physical interfaces)
WiFi AP — Antares
Interface: wlp6s0, mode ap, band bg (2.4 GHz), channel auto
Security: WPA-PSK
IP config: disabled on the AP interface itself — meaning wlp6s0 is a member of the crew-lan-bridge
Crew LAN Bridge (crew-lan-bridge)
Type: Linux bridge, ipv4.method: shared
Address: 192.168.42.1/24
Acts as router+DHCP server for WiFi clients (NetworkManager shared mode runs dnsmasq automatically)
Intended members: wlp6s0 (WiFi AP) and seabird-wired-member (one of the wired ports)
Currently both member ports have no carrier — the bridge exists but has no active physical members at this moment
Podman container network
Bridge podman0 at 10.88.0.1/16
6 veth pairs connecting the 6 containers
Containers are trusted by nftables (can access everything)
But are hard-blocked from receiving inbound connections from WAN/physical interfaces via the iptables DROP rules
Containers can reach out to internet via NAT through wwan0
Summary diagram
￼
Internet    │  wwan0  (LTE, 100.102.68.22)    │  NAT (nftables lan-to-wan + iptables ts-masquerade)    ├── tailscale0 (100.64.0.1) ←→ thinkpadl14, oneplus8, duat …    │seabird (Fedora Linux)    │    ├── crew-lan-bridge (192.168.42.1/24)  DHCP for clients    │       └── wlp6s0 [AP: "Antares", WPA-PSK, 2.4GHz]    │             └── (WiFi clients get 192.168.42.x)    │    └── podman0 (10.88.0.1/16)            ├── influxdb   :8086            ├── signalk    :3000            ├── grafana    :3001            ├── homepage   :3002            ├── nextcloud  :8080 (+ db, redis, cron, infra)            ├── navidrome  :4533            ├── pihole     :53            └── caddy      :80/443  (reverse proxy / TLS)
One notable thing: crew-lan-bridge has no active member ports right now (end0 and wlan1 both down), so WiFi clients get DHCP and routing via the bridge but it's currently an idle definition. Once you connect end0 or another wired port, it will bridge wired+wireless together.

Internet
    │
  wwan0  (LTE, 100.102.68.22)
    │  NAT (nftables lan-to-wan + iptables ts-masquerade)
    ├── tailscale0 (100.64.0.1) ←→ thinkpadl14, oneplus8, duat …
    │
seabird (Fedora Linux)
    │
    ├── crew-lan-bridge (192.168.42.1/24)  DHCP for clients
    │       └── wlp6s0 [AP: "Antares", WPA-PSK, 2.4GHz]
    │             └── (WiFi clients get 192.168.42.x)
    │
    └── podman0 (10.88.0.1/16)
            ├── influxdb   :8086
            ├── signalk    :3000
            ├── grafana    :3001
            ├── homepage   :3002
            ├── nextcloud  :8080 (+ db, redis, cron, infra)
            ├── navidrome  :4533
            ├── pihole     :53
            └── caddy      :80/443  (reverse proxy / TLS)   


cockpit can't connect websocket
Problem 1: lan zone (WiFi crew — wlp6s0) — Cockpit blocked
The lan zone has target: ACCEPT but lists explicit allowed services:


services: dhcp dhcpv6 dns http https mdns ssh
cockpit is not in that list. Despite target: ACCEPT sounding permissive, when services are explicitly listed in firewalld it still drops traffic not matching them for non-ACCEPT-target zones... but more importantly, cockpit is only in FedoraServer (the default catch-all zone with no assigned interface). Since wlp6s0 is assigned to lan, traffic arriving there is handled by lan rules, not FedoraServer. Port 9090 is simply never permitted inbound on the WiFi interface.

Fix:
firewall-cmd --zone=lan --add-service=cockpit --permanent
firewall-cmd --reload

firewall-cmd --zone=lan --add-service=cockpit --permanentfirewall-cmd --reload
Problem 2: headnet zone (Tailscale — tailscale0) — Cockpit also blocked
The headnet zone has target: ACCEPT but zero services listed at all. With target: ACCEPT and no explicit rules, it should accept everything — but that target: ACCEPT only applies to traffic that doesn't match any rule. Since headnet has forward: no and no services, and Cockpit's WebSocket upgrade goes through cockpit.socket on [::]:9090... the issue here is subtler: target: ACCEPT on the zone does let traffic through, so Tailscale clients should actually be able to reach port 9090. Let me verify whether the WebSocket failure from Tailscale is a different cause — Cockpit's own config:


disallow-root
/etc/cockpit/cockpit.conf shows disallow-root. Since you're logging in as root, Cockpit itself rejects the root login even if the TCP connection succeeds. The WebSocket handshake completes but authentication fails.

Fix (if you need root access via Cockpit):


# Either remove the restriction:ssh root@100.64.0.1 "sed -i '/disallow-root/d' /etc/cockpit/cockpit.conf"# Or use a non-root admin user instead.
Summary
Interface	Problem	Fix
wlp6s0 (crew WiFi)	lan zone doesn't include cockpit service → port 9090 firewalled	firewall-cmd --zone=lan --add-service=cockpit --permanent
tailscale0 (tailnet)	TCP reaches Cockpit, but disallow-root in /etc/cockpit/cockpit.conf blocks login → WS auth fails	Remove disallow-root or use a non-root user
wwan0 (WAN)	wan zone has target: DROP — correct, Cockpit should not be internet-exposed




desired state:
br-crew (192.168.42.0/24, dhcp, dns resolver pihole on localhost )
  - crew wifi (Intel PCIe card, ap name as per configuration script)
  - local LAN port (USB attached port)
upstream
  - marina wifi (CM4 onboard, connect to available wifi) (priority 1)
  - local LAN port (CM4 onboard, available to connect wired upstream such as satellite modem) (priority 2)
  - 5G modem (priority 3)
VPN
  - Tailscale as configured 

crew networks and VPN should provide unlimited access to local resources

---

## 2026-05-20 Live Check vs Desired State (host: 100.64.0.1)

### Verified discrepancies

1) br-crew is configured in NetworkManager but not active as an effective bridge datapath
- `crew-lan-bridge` exists and has `ifname br-crew`, `ipv4.method shared`, `192.168.42.1/24`.
- However, `ip -br addr` does not show `br-crew` active.
- Only `wlp6s0` AP is active; no bridge master/member relationship is visible in active connection state.

2) AP and wired member are not attached to the bridge in NM metadata
- `seabird-ap` and `seabird-wired-member` have no `connection.master` and no `connection.slave-type`.
- This means they are independent profiles, not persistent bridge ports.
- Root cause: old setup used `ip link set ... master br-crew` (runtime only), instead of NM-managed bridge slaves.

3) Crew wired-port role does not match desired hardware split
- Desired: crew LAN wired member should be USB-attached port.
- Existing script default was `enp4s0` (onboard), which conflicts with desired upstream use of onboard LAN.

4) Upstream priority intent is not fully enforced
- Desired order: marina WiFi (1), onboard wired upstream (2), 5G modem (3).
- Live state:
  - `Marina-Hafen_Gast` points to `wlan0` (device not present in current `nmcli device status`).
  - `Wired connection 1` has autoconnect-priority `-999` (effectively deprioritized/disabled).
  - `seabird-wwan` is active with high route metric fallback behavior (good for backup).

5) Cockpit from crew LAN still blocked by zone service list
- `lan` zone active on `wlp6s0` with services: `dhcp dhcpv6 dns http https mdns ssh`.
- `cockpit` service is not listed, so crew-side access to `:9090` remains blocked.

### Planned remediations

R1. Move bridge creation and membership fully into NetworkManager
- Create `crew-lan-bridge` as `type bridge` on `br-crew`.
- Configure bridge IP/DHCP at bridge level only (`ipv4.method shared`, `192.168.42.1/24`).
- Configure `seabird-ap` as AP bridge port with:
  - `connection.master=crew-lan-bridge`
  - `connection.slave-type=bridge`
  - `ipv4.method=disabled`
- Configure `seabird-wired-member` as ethernet bridge port with same master/slave settings.

R2. Align crew wired default with desired hardware mapping
- Use `end0` (USB-attached) as default crew wired bridge member.
- Keep onboard `enp4s0` available for upstream-wired role.

R3. Keep DHCP/DNS behavior explicit for crew clients
- Continue generating `seabird-crew-bridge.conf` in `/etc/NetworkManager/dnsmasq-shared.d/`.
- Keep DHCP range and DNS option (`pihole first, Quad9 fallback`) explicit.

R4. Enable Cockpit from crew LAN while keeping WAN locked down
- Add `cockpit` service to `lan` zone.
- Do not open Cockpit on `wan` zone (still `target DROP`).

R5. Follow-up (separate upstream script/task)
- Rebind marina WiFi profile to actual CM4 WiFi interface name.
- Set deterministic autoconnect priorities:
  - marina WiFi highest,
  - onboard wired upstream second,
  - WWAN third.
- Keep WWAN as reliable fallback if preferred links unavailable.

### Script compliance updates performed in this repo

- `scripts/install-crew-bridge.sh`
  - switched from mixed kernel+NM bridge model to NM-native bridge + bridge ports,
  - changed default crew wired member to `end0`,
  - added `--wired-iface` override,
  - ensures Cockpit service is added to `lan` zone.

- `scripts/install-crew-lan.sh`
  - clarified it is standalone/fallback mode,
  - changed default interface to `end0` and default subnet to `192.168.42.1/24`,
  - added `--iface` and `--pihole-ip` options,
  - keeps onboard `enp4s0` free for upstream role by default.
