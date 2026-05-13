#!/usr/bin/env python3
import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

LOG_DIR = os.environ.get("BEACON_LOG_DIR", "/logs")
LOG_FILE = os.path.join(LOG_DIR, "beacons.jsonl")
PORT = int(os.environ.get("BEACON_PORT", "8080"))

os.makedirs(LOG_DIR, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "client_ip": self.client_address[0],
            "path": parsed.path,
            "query": {k: v if len(v) > 1 else v[0] for k, v in parse_qs(parsed.query).items()},
            "user_agent": self.headers.get("User-Agent"),
        }
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, sort_keys=True) + "\n")

        body = (json.dumps({"ok": True, "event": event}, sort_keys=True) + "\n").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Listening on 0.0.0.0:{PORT}, logging to {LOG_FILE}", flush=True)
    server.serve_forever()
