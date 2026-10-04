"""Push Daly BMS samples to a Signal K server as deltas over a WebSocket.

Authentication uses Signal K's device access-request flow: on first run the sink
registers an access request; an admin approves it once in the Signal K admin UI
(Security -> Access Requests), after which a permanent token is stored in
``token_file`` and reused on every subsequent run.
"""

import asyncio
import json
import os
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

try:
    import websockets
except ImportError:  # dependency is optional; sink degrades to a no-op with a warning
    websockets = None


def _battery_id(name: str, mapping: dict) -> str:
    if name in mapping:
        return mapping[name]
    slug = "".join(c if c.isalnum() else "-" for c in name).strip("-").lower()
    return slug or "battery"


def _sk_values(bid: str, data: dict, invert_current: bool) -> list[dict]:
    """Map a Daly payload to Signal K electrical.batteries paths (SI units)."""
    base = f"electrical.batteries.{bid}"
    values: list[dict] = []

    def add(path: str, value) -> None:
        if isinstance(value, (int, float)):
            values.append({"path": path, "value": float(value)})

    sign = -1.0 if invert_current else 1.0
    add(f"{base}.voltage", data.get("voltage"))
    current = data.get("current")
    if isinstance(current, (int, float)):
        add(f"{base}.current", sign * float(current))
    power = data.get("power")
    if isinstance(power, (int, float)):
        add(f"{base}.power", sign * float(power))

    soc = data.get("battery_level")
    if isinstance(soc, (int, float)):
        add(f"{base}.capacity.stateOfCharge", float(soc) / 100.0)

    temperature = data.get("temperature")
    if isinstance(temperature, (int, float)):
        add(f"{base}.temperature", float(temperature) + 273.15)

    cells = data.get("cell_voltages")
    if isinstance(cells, list):
        for idx, cell_v in enumerate(cells, start=1):
            add(f"{base}.cells.{idx}.voltage", cell_v)

    faults = data.get("faults")
    if isinstance(faults, list):
        values.append({"path": f"{base}.faults", "value": "; ".join(faults) or "None"})
    problem_code_hex = data.get("problem_code_hex")
    if isinstance(problem_code_hex, str):
        values.append({"path": f"{base}.problemCode", "value": problem_code_hex})
    if isinstance(data.get("problem"), bool):
        values.append({"path": f"{base}.problem", "value": data["problem"]})

    return values


class SignalKSink:
    """Sends BMS samples to Signal K, acquiring a device token on first use."""

    def __init__(self, conf: dict, log=print) -> None:
        self.enabled = bool(conf.get("enabled", False))
        self.http_url = str(conf.get("http_url", "http://localhost:3000")).rstrip("/")
        default_ws = self.http_url.replace("http", "ws", 1) + "/signalk/v1/stream?subscribe=none"
        self.ws_url = str(conf.get("ws_url", default_ws))
        self.token_file = str(conf.get("token_file", "signalk_token.txt"))
        self.state_file = str(conf.get("state_file", self.token_file + ".request.json"))
        self.source_label = str(conf.get("source_label", "dalymon"))
        self.battery_ids = dict(conf.get("battery_ids", {}))
        self.invert_current = bool(conf.get("invert_current", False))
        self.log = log
        self.token: str | None = None
        self.client_id: str | None = None
        self._warned_no_ws = False
        self._load_token()

    # ---- token storage --------------------------------------------------
    def _load_token(self) -> None:
        if os.path.exists(self.token_file):
            with open(self.token_file, encoding="utf-8") as f:
                token = f.read().strip()
                if token:
                    self.token = token

    def _save_token(self, token: str) -> None:
        fd = os.open(self.token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(token + "\n")
        self.token = token

    # ---- access-request flow (blocking; run via asyncio.to_thread) ------
    def _http_json(self, method: str, url: str, payload=None):
        body = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=10) as resp:
            text = resp.read().decode()
            return resp.status, (json.loads(text) if text else {})

    def _ensure_token_sync(self) -> bool:
        if self.token:
            return True

        href = None
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file, encoding="utf-8") as f:
                    state = json.load(f)
                href = state.get("href")
                self.client_id = state.get("clientId")
            except (OSError, ValueError):
                href = None

        if href:
            try:
                _, body = self._http_json("GET", self.http_url + href)
            except (urllib.error.URLError, OSError, ValueError) as e:
                self.log(f"[signalk] Access request poll failed: {e}")
                return False
            access = body.get("accessRequest", {})
            permission = access.get("permission")
            if permission == "APPROVED" and access.get("token"):
                self._save_token(access["token"])
                self.log("[signalk] Access request approved; token stored")
                try:
                    os.remove(self.state_file)
                except OSError:
                    pass
                return True
            if permission == "DENIED":
                self.log("[signalk] Access request was denied; requesting again")
                href = None
            else:
                self.log("[signalk] Waiting for admin approval in Signal K (Security -> Access Requests)")
                return False

        self.client_id = self.client_id or str(uuid.uuid4())
        try:
            _, body = self._http_json(
                "POST",
                self.http_url + "/signalk/v1/access/requests",
                {"clientId": self.client_id, "description": "Daly BMS monitor (dalymon)"},
            )
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.log(f"[signalk] Failed to create access request: {e}")
            return False

        new_href = body.get("href")
        if new_href:
            try:
                with open(self.state_file, "w", encoding="utf-8") as f:
                    json.dump({"href": new_href, "clientId": self.client_id}, f)
            except OSError:
                pass
            self.log(f"[signalk] Requested device access; approve it at {self.http_url} -> Security -> Access Requests")
        else:
            self.log(f"[signalk] Unexpected access-request response: {body}")
        return False

    # ---- delta send -----------------------------------------------------
    async def send(self, name: str, data: dict) -> None:
        if not self.enabled:
            return
        if websockets is None:
            if not self._warned_no_ws:
                self.log("[signalk] 'websockets' package not installed; Signal K export disabled")
                self._warned_no_ws = True
            return
        if not self.token and not await asyncio.to_thread(self._ensure_token_sync):
            return

        bid = _battery_id(name, self.battery_ids)
        values = _sk_values(bid, data, self.invert_current)
        if not values:
            return

        delta = {
            "updates": [
                {
                    "source": {"label": self.source_label},
                    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                    "values": values,
                }
            ]
        }
        try:
            async with websockets.connect(
                self.ws_url,
                additional_headers={"Authorization": f"Bearer {self.token}"},
                open_timeout=10,
                close_timeout=5,
            ) as ws:
                await ws.send(json.dumps(delta))
            self.log(f"[{name}] Sent {len(values)} values to Signal K as '{bid}'")
        except Exception as e:  # noqa: BLE001 - network send is best-effort
            self.log(f"[{name}] Signal K send failed: {e}")
