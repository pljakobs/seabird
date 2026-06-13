#!/usr/bin/env python3
"""
seabird-weather-api — tiny HTTP API for weather overlay time/layer switching.

Endpoints (all on port 8089, routed via Caddy /wxapi/):
  GET  /wxapi/meta           — return weather-meta.json
  POST /wxapi/switch         — switch active run/hour/layers
                               body: {"run":"2026061306","hour":3,"layers":["wind-barbs"]}

On switch:
  • Atomically re-points stable symlinks (e.g. weather-wind-barbs.mbtiles)
    to the requested run+hour file.
  • Updates weather-meta.json with the new active state.
  • AvNav re-reads each SQLite MBTiles file on the next tile request,
    so no AvNav restart is needed.
"""

import http.server
import json
import os
import re
import sys
import traceback
from datetime import datetime, timezone

LISTEN_ADDR = ("127.0.0.1", 8089)
META_PATH   = "/srv/seabird/avnav/user/viewer/weather-meta.json"
CHART_DIR   = "/srv/seabird/avnav/charts"


def load_meta():
    with open(META_PATH) as f:
        return json.load(f)


def save_meta(data):
    tmp = META_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, META_PATH)


def switch_symlinks(run_id, hour, prefix, active_layers):
    """Re-point stable symlinks for active layers; remove symlinks for hidden ones.

    active_layers=None means show all available layers.
    """
    fh = f"{int(hour):03d}"
    suffix = f"-{run_id}+{fh}"
    switched = []
    hidden   = []
    errors   = []

    for entry in os.listdir(CHART_DIR):
        if not entry.endswith(suffix + ".mbtiles"):
            continue
        stable = entry.replace(suffix + ".mbtiles", ".mbtiles")
        if stable == entry:
            continue

        # Derive layer_id: strip prefix (e.g. "weather-") and ".mbtiles"
        layer_id = stable
        if layer_id.startswith(prefix):
            layer_id = layer_id[len(prefix):]
        if layer_id.endswith(".mbtiles"):
            layer_id = layer_id[:-len(".mbtiles")]

        target = os.path.join(CHART_DIR, stable)
        if active_layers is None or layer_id in active_layers:
            tmp_link = target + ".switching"
            try:
                os.symlink(entry, tmp_link)
                os.replace(tmp_link, target)
                switched.append(stable)
            except Exception as exc:
                errors.append(f"{stable}: {exc}")
        else:
            try:
                if os.path.islink(target):
                    os.unlink(target)
                    hidden.append(stable)
            except Exception as exc:
                errors.append(f"{stable} (hide): {exc}")

    return switched, hidden, errors


class WeatherAPIHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # suppress default access log noise
        pass

    def send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
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
        if path in ("/wxapi/meta", "/meta"):
            try:
                meta = load_meta()
                self.send_json(200, meta)
            except FileNotFoundError:
                self.send_json(503, {"error": "weather-meta.json not yet generated"})
            except Exception as exc:
                self.send_json(500, {"error": str(exc)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?", 1)[0].rstrip("/") not in ("/wxapi/switch", "/switch"):
            self.send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            req = json.loads(body) if body else {}
        except Exception:
            self.send_json(400, {"error": "invalid JSON body"})
            return

        try:
            meta = load_meta()
        except Exception as exc:
            self.send_json(503, {"error": f"cannot read meta: {exc}"})
            return

        run_id     = req.get("run",    meta.get("active_run"))
        hour       = int(req.get("hour", meta.get("active_hour", 3)))
        prefix     = meta.get("chart_prefix", "weather-")
        # Resolve active_layers: explicit from request, else keep existing, else all
        if "layers" in req:
            layers = req["layers"]  # explicit (may be [] to hide all)
        else:
            layers = meta.get("active_layers")  # None = show all
        valid_runs = {r["id"]: r for r in meta.get("runs", [])}
        if run_id not in valid_runs:
            self.send_json(400, {"error": f"unknown run '{run_id}'"})
            return

        run_info = valid_runs[run_id]
        if hour not in run_info.get("hours", []):
            self.send_json(400, {
                "error": f"hour {hour} not available for run {run_id}",
                "available": run_info.get("hours"),
            })
            return

        switched, hidden, errors = switch_symlinks(run_id, hour, prefix, layers)

        meta["active_run"]    = run_id
        meta["active_hour"]   = hour
        meta["active_layers"] = layers
        meta["switched_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
        save_meta(meta)

        self.send_json(200, {
            "ok": True,
            "active_run":    run_id,
            "active_hour":   hour,
            "active_layers": layers,
            "switched":      switched,
            "hidden":        hidden,
            "errors":        errors,
        })


if __name__ == "__main__":
    if not os.path.isdir(CHART_DIR):
        print(f"CHART_DIR {CHART_DIR!r} not found — aborting", file=sys.stderr)
        sys.exit(1)
    server = http.server.HTTPServer(LISTEN_ADDR, WeatherAPIHandler)
    print(f"seabird-weather-api listening on {LISTEN_ADDR[0]}:{LISTEN_ADDR[1]}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
