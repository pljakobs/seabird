#!/usr/bin/env python3
"""
seabird-wifi-api — tiny host HTTP bridge to nmcli for upstream WiFi management.

NetworkManager (and therefore nmcli) runs on the host, not inside the homepage
container, so this small service exposes a LAN-only API + UI that lets the crew
pick which marina / harbour WiFi the onboard upstream radio connects to.

It mirrors the seabird-weather-api pattern: binds 127.0.0.1 only, is reached via
Caddy (handle /wifiapi*), and shells out to nmcli using argument lists (never a
shell) so SSIDs/passwords cannot inject commands.

Endpoints (all under /wifiapi/, routed via Caddy):
  GET  /wifiapi/          — interactive scan/select/connect page (HTML)
  GET  /wifiapi/status    — current upstream connection (JSON)
  GET  /wifiapi/scan      — rescan + list available networks, filtered (JSON)
  GET  /wifiapi/widget    — compact status for the Homepage customapi widget
  POST /wifiapi/connect   — body {"ssid": "...", "password": "..."} → connect

Networks whose SSID is listed in the negative filter file (default
/etc/seabird/wifi-filter.conf, one SSID per line, '#' comments) are hidden —
seeded by the installer with the crew AP SSID so the boat's own network is never
offered as an upstream.
"""

import http.server
import json
import os
import subprocess

LISTEN_ADDR = ("127.0.0.1", 8090)

# The crew AP radio is excluded so upstream scans/connects never steal it.
AP_IFACE       = os.environ.get("SEABIRD_AP_IFACE", "wlp6s0")
UPSTREAM_IFACE = os.environ.get("SEABIRD_UPSTREAM_IFACE", "")
FILTER_PATH    = os.environ.get("SEABIRD_WIFI_FILTER", "/etc/seabird/wifi-filter.conf")


def run(args, timeout=30):
    """Run a command (no shell) and return stdout; raise on failure."""
    proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "command failed").strip()
        raise RuntimeError(msg)
    return proc.stdout


def split_nmcli(line):
    """Split one line of `nmcli -t` output, honouring '\\:' / '\\\\' escapes."""
    fields, cur, i = [], [], 0
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line):
            cur.append(line[i + 1])
            i += 2
            continue
        if c == ":":
            fields.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    fields.append("".join(cur))
    return fields


def detect_upstream_iface():
    """Any WiFi device that is not the AP card; prefer the brcmfmac onboard radio."""
    if UPSTREAM_IFACE:
        return UPSTREAM_IFACE
    best = ""
    out = run(["nmcli", "-t", "-f", "DEVICE,TYPE", "device", "status"])
    for line in out.splitlines():
        f = split_nmcli(line)
        if len(f) < 2 or f[1] != "wifi":
            continue
        dev = f[0]
        if dev == AP_IFACE or dev.startswith("p2p-"):
            continue
        driver = os.path.basename(
            os.path.realpath(f"/sys/class/net/{dev}/device/driver")
        ) if os.path.exists(f"/sys/class/net/{dev}/device/driver") else ""
        if driver == "brcmfmac":
            return dev
        if not best:
            best = dev
    return best


def load_filter():
    """SSIDs to hide from the upstream list (negative filter)."""
    hidden = set()
    try:
        with open(FILTER_PATH) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    hidden.add(line)
    except FileNotFoundError:
        pass
    return hidden


def saved_profiles():
    """Names of saved WiFi connection profiles (name usually equals the SSID)."""
    names = set()
    try:
        out = run(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
    except Exception:
        return names
    for line in out.splitlines():
        f = split_nmcli(line)
        if len(f) >= 2 and f[1] == "802-11-wireless":
            names.add(f[0])
    return names


def scan_networks(iface, rescan=True):
    hidden = load_filter()
    saved = saved_profiles()
    out = run(
        ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY",
         "device", "wifi", "list", "ifname", iface,
         "--rescan", "yes" if rescan else "no"],
        timeout=40,
    )
    nets = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        f = split_nmcli(line)
        if len(f) < 4:
            continue
        in_use, ssid, signal, security = f[0], f[1], f[2], f[3]
        if not ssid or ssid in hidden:
            continue
        try:
            sig = int(signal)
        except ValueError:
            sig = 0
        rec = nets.get(ssid)
        if rec is None or sig > rec["signal"]:
            nets[ssid] = {
                "ssid": ssid,
                "signal": sig,
                "security": security or "open",
                "secured": bool(security) and security != "--",
                "in_use": in_use.strip() == "*",
                "saved": ssid in saved,
            }
    return sorted(nets.values(), key=lambda n: n["signal"], reverse=True)


def upstream_status(iface):
    connected, signal = None, None
    try:
        out = run(
            ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL",
             "device", "wifi", "list", "ifname", iface, "--rescan", "no"],
            timeout=15,
        )
        for line in out.splitlines():
            f = split_nmcli(line)
            if len(f) >= 3 and f[0].strip() == "*":
                connected = f[1]
                try:
                    signal = int(f[2])
                except ValueError:
                    signal = None
                break
    except Exception:
        pass

    ip = None
    try:
        out = run(["nmcli", "-t", "-f", "IP4.ADDRESS", "device", "show", iface],
                  timeout=10)
        for line in out.splitlines():
            if ":" in line:
                ip = line.split(":", 1)[1]
                break
    except Exception:
        pass

    return {"interface": iface, "connected": connected, "signal": signal, "ip": ip}


def connect_network(iface, ssid, password):
    """Connect the upstream radio to ssid; reuse a saved profile when present."""
    if ssid in saved_profiles():
        run(["nmcli", "connection", "up", "id", ssid], timeout=60)
    else:
        args = ["nmcli", "device", "wifi", "connect", ssid, "ifname", iface]
        if password:
            args += ["password", password]
        run(args, timeout=60)


def device_state(dev):
    """NetworkManager device state, e.g. connected/disconnected/unavailable."""
    try:
        out = run(["nmcli", "-t", "-f", "DEVICE,STATE", "device", "status"], timeout=10)
    except Exception:
        return "unavailable"
    for line in out.splitlines():
        f = split_nmcli(line)
        if len(f) >= 2 and f[0] == dev:
            return f[1]
    return "unavailable"


def crew_wlan_status():
    """Crew AP: up when the AP radio is active, plus associated WiFi client count."""
    up = device_state(AP_IFACE) == "connected"
    clients = 0
    try:
        out = run(["iw", "dev", AP_IFACE, "station", "dump"], timeout=10)
        clients = sum(1 for ln in out.splitlines() if ln.startswith("Station"))
    except Exception:
        pass
    return {"up": up, "clients": clients}


def cellular_status():
    """WWAN modem state via ModemManager (mmcli)."""
    idx = None
    try:
        out = run(["mmcli", "-L", "-K"], timeout=10)
        for line in out.splitlines():
            if "/Modem/" in line:
                idx = line.rsplit("/", 1)[1].strip()
                break
    except Exception:
        return {"present": False, "state": "absent", "signal": None, "access": ""}
    if idx is None:
        return {"present": False, "state": "absent", "signal": None, "access": ""}

    state, signal, access, provider = "unknown", None, "", ""
    try:
        out = run(["mmcli", "-m", idx, "-K"], timeout=10)
        d = {}
        for line in out.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                d[k.strip()] = v.strip()
        state = d.get("modem.generic.state", "unknown")
        sq = d.get("modem.generic.signal-quality.value", "")
        if sq.isdigit():
            signal = int(sq)
        technologies = [value for key, value in d.items()
                        if key.startswith("modem.generic.access-technologies.value[")
                        and value != "--"]
        access = "/".join("5G" if value == "5gnr" else value.upper()
                          for value in technologies)
        provider = d.get("modem.3gpp.operator-name", "")
        if provider == "--":
            provider = ""
    except Exception:
        pass
    return {"present": True, "state": state, "signal": signal, "access": access,
            "provider": provider}


def widget_payload():
    """Compact, pre-formatted status for the Homepage customapi widget.

    customapi can't colour fields or show tooltips, so status colour is carried
    as a leading emoji and the SSID/count is shown inline in the text value.
    """
    iface = detect_upstream_iface()

    crew = crew_wlan_status()
    if crew["up"]:
        n = crew["clients"]
        crew_s = f"🟢 {n} client" + ("" if n == 1 else "s")
    else:
        crew_s = "🔴 down"

    if iface:
        state = device_state(iface)
        st = upstream_status(iface)
    else:
        state, st = "unavailable", {"connected": None, "signal": None}
    if state == "connected" and st.get("connected"):
        sig = st.get("signal")
        up_s = f"🟢 {st['connected']}" + (f" {sig}%" if sig is not None else "")
    elif state in ("disconnected", "connecting", "prepare", "config", "need-auth"):
        up_s = "🔵 not connected"
    else:
        up_s = "🔴 unavailable"

    cell = cellular_status()
    if cell["present"] and cell["state"] in ("registered", "connected"):
        acc = (cell["access"] or "cell").upper()
        sig = cell["signal"]
        provider = cell.get("provider", "")
        connection = f"{provider} / {acc}" if provider else acc
        cell_s = f"🟢 {connection}" + (f" {sig}%" if sig is not None else "")
    elif cell["present"]:
        cell_s = "🔴 no signal"
    else:
        cell_s = "🔴 no modem"

    return {"crew": crew_s, "upstream": up_s, "cellular": cell_s}


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Seabird — Upstream WiFi</title>
<style>
  :root { color-scheme: dark; }
  body { font-family: system-ui, sans-serif; margin: 0; background:#111; color:#eee; }
  header { padding: 16px; background:#1b1b1b; border-bottom:1px solid #333; }
  h1 { font-size: 1.1rem; margin: 0; }
  .status { padding: 12px 16px; color:#9cf; font-size:.9rem; min-height:1.2em; }
  main { padding: 8px 16px 24px; max-width: 640px; }
  button { font: inherit; cursor:pointer; }
  .scan { background:#2563eb; color:#fff; border:0; border-radius:8px; padding:10px 16px; }
  ul { list-style:none; margin:12px 0 0; padding:0; }
  li { display:flex; align-items:center; gap:10px; padding:12px; border:1px solid #333;
       border-radius:8px; margin-bottom:8px; background:#1b1b1b; }
  .ssid { flex:1; font-weight:600; }
  .meta { color:#999; font-size:.8rem; }
  .bars { font-variant-numeric: tabular-nums; width:3.2em; text-align:right; color:#9cf; }
  .in-use { color:#4ade80; }
  .connect { background:#374151; color:#fff; border:0; border-radius:6px; padding:6px 12px; }
  .pw { margin-top:8px; display:flex; gap:8px; }
  .pw input { flex:1; padding:8px; border-radius:6px; border:1px solid #444; background:#111; color:#eee; }
  .msg { padding:12px 16px; font-size:.9rem; }
</style>
</head>
<body>
<header><h1>Upstream WiFi</h1></header>
<div class="status" id="status">Loading status…</div>
<main>
  <button class="scan" id="scan">Scan networks</button>
  <div class="msg" id="msg"></div>
  <ul id="list"></ul>
</main>
<script>
const api = (p) => new URL(p, location.href).toString();
const statusEl = document.getElementById('status');
const listEl = document.getElementById('list');
const msgEl = document.getElementById('msg');

function signalBars(s) {
  if (s >= 75) return '▂▄▆█';
  if (s >= 50) return '▂▄▆_';
  if (s >= 25) return '▂▄__';
  return '▂___';
}

async function loadStatus() {
  try {
    const r = await fetch(api('status'));
    const d = await r.json();
    statusEl.textContent = d.connected
      ? `Connected to ${d.connected}` + (d.signal != null ? ` (${d.signal}%)` : '')
        + (d.ip ? ` — ${d.ip}` : '')
      : `Not connected (${d.interface || 'upstream'})`;
  } catch (e) { statusEl.textContent = 'Status unavailable'; }
}

function render(nets) {
  listEl.innerHTML = '';
  if (!nets.length) { msgEl.textContent = 'No networks found.'; return; }
  msgEl.textContent = '';
  for (const n of nets) {
    const li = document.createElement('li');
    const name = document.createElement('div');
    name.className = 'ssid';
    name.textContent = n.ssid + (n.secured ? ' 🔒' : '');
    if (n.in_use) name.classList.add('in-use');
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = [n.security, n.saved ? 'saved' : ''].filter(Boolean).join(' · ');
    const bars = document.createElement('div');
    bars.className = 'bars';
    bars.textContent = signalBars(n.signal);
    const btn = document.createElement('button');
    btn.className = 'connect';
    btn.textContent = n.in_use ? 'Connected' : 'Connect';
    btn.disabled = n.in_use;
    btn.onclick = () => startConnect(li, n);
    const left = document.createElement('div');
    left.style.flex = '1';
    left.appendChild(name);
    left.appendChild(meta);
    li.appendChild(bars);
    li.appendChild(left);
    li.appendChild(btn);
    listEl.appendChild(li);
  }
}

function startConnect(li, n) {
  if (n.secured && !n.saved) {
    if (li.querySelector('.pw')) return;
    const box = document.createElement('div');
    box.className = 'pw';
    const inp = document.createElement('input');
    inp.type = 'password';
    inp.placeholder = 'Password';
    inp.autocomplete = 'off';
    const go = document.createElement('button');
    go.className = 'connect';
    go.textContent = 'Go';
    go.onclick = () => doConnect(n.ssid, inp.value);
    inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') go.click(); });
    box.appendChild(inp);
    box.appendChild(go);
    li.appendChild(box);
    inp.focus();
  } else {
    doConnect(n.ssid, '');
  }
}

async function doConnect(ssid, password) {
  msgEl.textContent = `Connecting to ${ssid}…`;
  try {
    const r = await fetch(api('connect'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ssid, password }),
    });
    const d = await r.json();
    if (d.ok) {
      msgEl.textContent = `Connected to ${ssid}.`;
      await loadStatus();
      await scan(false);
    } else {
      msgEl.textContent = `Failed: ${d.error || 'unknown error'}`;
    }
  } catch (e) { msgEl.textContent = `Failed: ${e}`; }
}

async function scan(rescan = true) {
  msgEl.textContent = 'Scanning…';
  try {
    const r = await fetch(api('scan') + (rescan ? '' : '?rescan=no'));
    const d = await r.json();
    if (d.error) { msgEl.textContent = d.error; return; }
    render(d.networks || []);
  } catch (e) { msgEl.textContent = `Scan failed: ${e}`; }
}

document.getElementById('scan').onclick = () => scan(true);
loadStatus();
scan(true);
</script>
</body>
</html>
"""


class WifiAPIHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # suppress default access log noise
        pass

    def _iface(self):
        iface = detect_upstream_iface()
        if not iface:
            raise RuntimeError("no upstream WiFi interface found")
        return iface

    def send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        path = path[len("/wifiapi"):] if path.startswith("/wifiapi") else path
        try:
            if path in ("", "/"):
                self.send_html(200, PAGE)
            elif path == "/status":
                self.send_json(200, upstream_status(self._iface()))
            elif path == "/scan":
                rescan = "rescan=no" not in self.path
                nets = scan_networks(self._iface(), rescan=rescan)
                self.send_json(200, {"networks": nets})
            elif path == "/widget":
                self.send_json(200, widget_payload())
            else:
                self.send_json(404, {"error": "not found"})
        except Exception as exc:
            self.send_json(500, {"error": str(exc)})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        path = path[len("/wifiapi"):] if path.startswith("/wifiapi") else path
        if path != "/connect":
            self.send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""
            req = json.loads(body) if body else {}
        except Exception:
            self.send_json(400, {"error": "invalid JSON body"})
            return

        ssid = req.get("ssid", "")
        password = req.get("password", "") or ""
        if not isinstance(ssid, str) or not ssid or len(ssid) > 32:
            self.send_json(400, {"error": "invalid ssid"})
            return
        if not isinstance(password, str) or len(password) > 63:
            self.send_json(400, {"error": "invalid password"})
            return
        if password and len(password) < 8:
            self.send_json(400, {"error": "password must be at least 8 characters"})
            return

        try:
            iface = self._iface()
            connect_network(iface, ssid, password)
        except subprocess.TimeoutExpired:
            self.send_json(504, {"error": "connection attempt timed out"})
            return
        except Exception as exc:
            self.send_json(502, {"ok": False, "error": str(exc)})
            return

        self.send_json(200, {"ok": True, **upstream_status(iface)})


if __name__ == "__main__":
    server = http.server.HTTPServer(LISTEN_ADDR, WifiAPIHandler)
    print(f"seabird-wifi-api listening on {LISTEN_ADDR[0]}:{LISTEN_ADDR[1]}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
