import asyncio
import argparse
import tomllib
import json
import os
import time
from datetime import datetime, timezone
from bleak import BleakScanner
from bleak.backends.device import BLEDevice
from aiobmsble.bms.daly_bms import BMS
from influxdb_client import InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS
from health_assessment import assess
from signalk_sink import SignalKSink
from faults import decode_daly_d2_faults, format_daly_d2_problem_code

INIT_RETRY_DELAY = 10         # first retry wait in seconds
MAX_RECONNECT_BACKOFF = 60    # cap retry backoff so we keep trying frequently
UPDATE_TIMEOUT = 20           # BMS update timeout in seconds
# A single long-lived scanner keeps BlueZ's device cache warm, so polls reuse a
# recent advertisement instead of racing a cold per-cycle scan (the old failure
# mode: "Device not found during scan" / "device disappeared").
DEVICE_FRESH_MAX_AGE = 180  # reuse an advertisement seen within this many seconds
DEVICE_WAIT_TIMEOUT = 90    # how long a poll waits for a fresh advertisement
SCANNER_STALL_TIMEOUT = 900 # restart the scanner if no device is seen this long
HEALTH_ASSESSMENT_INTERVAL_S = 3600
HEALTH_LOOKBACK_DAYS = 365
HEALTH_TOKEN_FILE = "dalymon_token.txt"


class DeviceRegistry:
    """Caches the freshest BLEDevice per address from a continuous scanner."""

    def __init__(self) -> None:
        self._devices: dict[str, BLEDevice] = {}
        self._last_seen: dict[str, float] = {}
        self._events: dict[str, asyncio.Event] = {}
        self._last_any_seen: float = time.monotonic()

    def register_interest(self, mac: str) -> None:
        self._events.setdefault(mac.upper(), asyncio.Event())

    def detection_callback(self, device: BLEDevice, _adv) -> None:
        mac = device.address.upper()
        self._devices[mac] = device
        now = time.monotonic()
        self._last_seen[mac] = now
        self._last_any_seen = now
        event = self._events.get(mac)
        if event is not None:
            event.set()

    def _age(self, mac: str):
        ts = self._last_seen.get(mac)
        return None if ts is None else time.monotonic() - ts

    def idle_seconds(self) -> float:
        return time.monotonic() - self._last_any_seen

    async def wait_fresh(self, mac: str, max_age: float, timeout: float):
        """Return a BLEDevice seen within max_age, waiting up to timeout."""
        mac = mac.upper()
        event = self._events.setdefault(mac, asyncio.Event())
        deadline = time.monotonic() + timeout
        while True:
            age = self._age(mac)
            if age is not None and age <= max_age:
                return self._devices.get(mac)
            event.clear()
            # Re-check after clearing to avoid missing a concurrent advertisement.
            age = self._age(mac)
            if age is not None and age <= max_age:
                return self._devices.get(mac)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            try:
                await asyncio.wait_for(event.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                return None


def utc_now_iso_z() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def add_telemetry_fields(point: Point, data: dict) -> Point:
    """Map full Daly payload to Influx fields with safe type handling."""
    for key, value in data.items():
        if value is None:
            continue

        if isinstance(value, bool):
            point = point.field(key, value)
            continue

        if isinstance(value, (int, float)):
            point = point.field(key, float(value))
            continue

        if isinstance(value, list):
            # Flatten per-cell and per-sensor arrays to queryable scalar fields.
            if key == "cell_voltages":
                for idx, cell_v in enumerate(value, start=1):
                    try:
                        point = point.field(f"cell_voltage_{idx}", float(cell_v))
                    except (TypeError, ValueError):
                        continue
            elif key == "temp_values":
                for idx, temp_v in enumerate(value, start=1):
                    try:
                        point = point.field(f"temp_value_{idx}", float(temp_v))
                    except (TypeError, ValueError):
                        continue

    point = point.field("problem_code_hex", data.get("problem_code_hex", "0x0000000000000000"))
    point = point.field("faults", "; ".join(data.get("faults", [])) or "None")
    point = point.field("fault_count", int(data.get("fault_count", 0)))

    # Keep legacy aliases used by existing panels.
    if "battery_level" in data:
        try:
            point = point.field("soc", float(data["battery_level"]))
        except (TypeError, ValueError):
            pass
    if "temperature" in data:
        try:
            point = point.field("temp", float(data["temperature"]))
        except (TypeError, ValueError):
            pass

    return point


def add_health_fields(point: Point, metrics: dict, warnings_count: int, remarks_count: int) -> Point:
    """Write a compact set of health metrics for dashboarding/trending."""
    numeric_fields = [
        "samples",
        "time_span_hours",
        "time_span_days",
        "step_events",
        "pack_ir_proxy_median_mohm",
        "cell_ir_proxy_median_mohm",
        "delta_v_median_low_soc_v",
        "delta_v_median_mid_soc_v",
        "delta_v_median_high_soc_v",
        "high_soc_samples",
        "temp_median_low_load_c",
        "temp_median_high_load_c",
        "temp_rise_proxy_c",
        "rest_windows",
        "rest_voltage_drift_median_v",
        "fault_events",
        "soc_span_pct",
    ]

    for key in numeric_fields:
        value = metrics.get(key)
        if isinstance(value, (int, float)):
            point = point.field(key, float(value))

    low_cell = metrics.get("most_frequent_low_cell_at_high_soc")
    high_cell = metrics.get("most_frequent_high_cell_at_high_soc")
    if isinstance(low_cell, tuple) and len(low_cell) == 2:
        point = point.field("frequent_low_cell_idx", int(low_cell[0]))
        point = point.field("frequent_low_cell_count", int(low_cell[1]))
    if isinstance(high_cell, tuple) and len(high_cell) == 2:
        point = point.field("frequent_high_cell_idx", int(high_cell[0]))
        point = point.field("frequent_high_cell_count", int(high_cell[1]))

    per_cell_ir = metrics.get("cell_ir_proxy_median_mohm_by_cell") or {}
    if isinstance(per_cell_ir, dict):
        for idx, ir in per_cell_ir.items():
            if isinstance(idx, int) and isinstance(ir, (int, float)):
                point = point.field(f"cell_ir_proxy_median_mohm_{idx}", float(ir))

    point = point.field("warnings_count", int(warnings_count))
    point = point.field("remarks_count", int(remarks_count))
    return point


def read_health_token(config: dict) -> str:
    """Load read token for health queries, preferring dalymon_token.txt."""
    if os.path.exists(HEALTH_TOKEN_FILE):
        with open(HEALTH_TOKEN_FILE, encoding="utf-8") as f:
            token = f.read().strip()
            if token:
                return token
    return config["influxdb"]["token"]


def load_rows_from_influx(config: dict) -> list[dict]:
    """Load historical battery rows from InfluxDB and shape for assess()."""
    def as_float(value, default=float("nan")):
        try:
            if value is None:
                return default
            return float(value)
        except (TypeError, ValueError):
            return default

    def as_int(value, default=0):
        try:
            if value is None:
                return default
            return int(value)
        except (TypeError, ValueError):
            return default

    battery_name = config["batteries"][0]["name"]
    flux = f'''
from(bucket: {json.dumps(config["influxdb"]["bucket"] )})
  |> range(start: -{HEALTH_LOOKBACK_DAYS}d)
  |> filter(fn: (r) => r._measurement == "battery_status")
  |> filter(fn: (r) => r.battery_name == {json.dumps(battery_name)})
  |> filter(fn: (r) =>
      r._field == "voltage" or
      r._field == "current" or
      r._field == "battery_level" or
      r._field == "delta_voltage" or
      r._field == "temperature" or
      r._field == "problem_code" or
      r._field == "problem" or
      r._field =~ /^cell_voltage_[0-9]+$/
  )
  |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"])
'''

    token = read_health_token(config)
    rows: list[dict] = []
    with InfluxDBClient(
        url=config["influxdb"]["url"],
        token=token,
        org=config["influxdb"]["org"],
    ) as client:
        query_api = client.query_api()
        for record in query_api.query_stream(query=flux, org=config["influxdb"]["org"]):
            ts = record.get_time()
            if ts is None:
                continue
            values = record.values
            row = {
                "timestamp": ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                "_ts": ts.astimezone(timezone.utc),
                "battery": battery_name,
                "voltage": as_float(values.get("voltage"), 0.0),
                "current": as_float(values.get("current"), 0.0),
                "battery_level": as_float(values.get("battery_level"), float("nan")),
                "delta_voltage": as_float(values.get("delta_voltage"), float("nan")),
                "temperature": as_float(values.get("temperature"), float("nan")),
                "problem_code": as_int(values.get("problem_code"), 0),
                "problem": bool(values.get("problem", False)),
            }

            # Reconstruct per-cell array from flattened fields.
            cell_pairs = []
            for key, value in values.items():
                if isinstance(key, str) and key.startswith("cell_voltage_"):
                    try:
                        idx = int(key.split("_")[-1])
                        if value is None:
                            continue
                        cell_pairs.append((idx, float(value)))
                    except (ValueError, TypeError):
                        continue
            if cell_pairs:
                row["cell_voltages"] = [v for _, v in sorted(cell_pairs)]
            else:
                row["cell_voltages"] = []

            rows.append(row)

    rows.sort(key=lambda r: r["_ts"])
    return rows


async def run_health_assessment(config, write_api):
    """Compute health summary from JSONL history and write to InfluxDB."""
    if write_api is None:
        return

    try:
        rows = await asyncio.to_thread(load_rows_from_influx, config)
        if not rows:
            print("[health] No rows available in InfluxDB for assessment")
            return
        result = assess(rows)
        metrics = result.get("metrics", {})
        warnings_count = len(result.get("warnings", []))
        remarks_count = len(result.get("remarks", []))

        point = Point("battery_health").tag("battery_name", config["batteries"][0]["name"])
        point = add_health_fields(point, metrics, warnings_count, remarks_count)
        write_api.write(
            bucket=config["influxdb"]["bucket"],
            org=config["influxdb"]["org"],
            record=point,
        )
        print("[health] Wrote battery health summary to InfluxDB")
    except Exception as e:
        print(f"[health] Assessment failed: {e}")


async def poll_once(config, battery_conf, write_api, jsonl_file, write_to_file, write_to_stdout, registry, sk_sink=None):
    """One scan+connect+read attempt. Returns True on success, False otherwise."""
    mac = battery_conf['address']
    name = battery_conf['name']

    device = await registry.wait_fresh(mac, DEVICE_FRESH_MAX_AGE, DEVICE_WAIT_TIMEOUT)
    if not device:
        # Not an error with a weak/flapping link: the advertisement just hasn't
        # arrived yet. The continuous scanner keeps listening; we retry shortly.
        print(f"[{name}] No advertisement yet (link weak/out of range), still scanning")
        return False

    try:
        async with BMS(ble_device=device) as bms:
            data = await asyncio.wait_for(bms.async_update(), timeout=UPDATE_TIMEOUT)
            data = dict(data)
            problem_code = data.get("problem_code", 0)
            faults = decode_daly_d2_faults(problem_code)
            data["problem_code_hex"] = format_daly_d2_problem_code(problem_code)
            data["faults"] = faults
            data["fault_count"] = len(faults)
            timestamp = utc_now_iso_z()

            # --- InfluxDB Export ---
            if config['influxdb']['enabled'] and write_api is not None:
                point = Point("battery_status").tag("battery_name", name)
                point = add_telemetry_fields(point, data)

                write_api.write(bucket=config['influxdb']['bucket'],
                                org=config['influxdb']['org'],
                                record=point)

            # --- JSONL Export ---
            record = {
                'timestamp': timestamp,
                'battery': name,
                **data,
            }
            json_line = json.dumps(record, ensure_ascii=True, default=str)

            if write_to_file and jsonl_file is not None:
                jsonl_file.write(json_line + "\n")
                jsonl_file.flush()

            if write_to_stdout:
                print(json_line)

            # --- Signal K Export ---
            if sk_sink is not None:
                await sk_sink.send(name, data)

            print(f"[{name}] Active Daly faults: {'; '.join(faults) or 'None'}")
            print(f"[{name}] Polled successfully: {data}")
            return True
    except Exception as e:
        print(f"[{name}] Connect/read failed: {e}")
        return False


async def battery_loop(config, battery_conf, write_api, jsonl_file, write_to_file, write_to_stdout, registry, sk_sink, poll_interval):
    """Perpetually scan, connect and poll one battery.

    Never gives up: on any failure it keeps retrying with a short capped backoff
    so it reconnects as soon as the (weak/flapping) link allows. This doubles as
    the loss-of-connection fallback — a dropped read simply loops back and
    reconnects instead of waiting a full poll interval.
    """
    name = battery_conf['name']
    backoff = INIT_RETRY_DELAY
    while True:
        ok = await poll_once(config, battery_conf, write_api, jsonl_file,
                             write_to_file, write_to_stdout, registry, sk_sink)
        if ok:
            backoff = INIT_RETRY_DELAY
            await asyncio.sleep(poll_interval)
        else:
            print(f"[{name}] Retrying in {backoff}s...")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, MAX_RECONNECT_BACKOFF)


async def health_loop(config, write_api):
    """Run the periodic health assessment independently of the poll loops."""
    while True:
        await asyncio.sleep(HEALTH_ASSESSMENT_INTERVAL_S)
        await run_health_assessment(config, write_api)


async def scanner_watchdog(registry, scanner):
    """Restart the scanner if the adapter appears wedged (nothing seen at all)."""
    while True:
        await asyncio.sleep(SCANNER_STALL_TIMEOUT)
        if registry.idle_seconds() > SCANNER_STALL_TIMEOUT:
            print("[main] No BLE advertisements seen recently, restarting scanner")
            try:
                await scanner.stop()
            except Exception as e:
                print(f"[main] Scanner stop failed: {e}")
            try:
                await scanner.start()
                print("[main] BLE scanner restarted")
            except Exception as e:
                print(f"[main] Scanner restart failed: {e}")


def parse_args():
    parser = argparse.ArgumentParser(description="Daly BMS monitoring daemon")
    parser.add_argument(
        "-c",
        "--config",
        default="daly.conf",
        help="Path to the TOML config file (default: daly.conf in cwd, system install: /etc/dalymon.conf)",
    )
    parser.add_argument(
        "-o",
        "--output",
        choices=["auto", "file", "stdout", "both"],
        default="auto",
        help="JSONL output sink: auto (from config), file, stdout, or both",
    )
    return parser.parse_args()


async def main(args):
    with open(args.config, "rb") as f:
        config = tomllib.load(f)

    config_file_output = config.get('jsonl', {}).get('enabled', False)
    if args.output == 'auto':
        write_to_file = config_file_output
        write_to_stdout = False
    elif args.output == 'file':
        write_to_file = True
        write_to_stdout = False
    elif args.output == 'stdout':
        write_to_file = False
        write_to_stdout = True
    else:  # both
        write_to_file = True
        write_to_stdout = True

    # Setup JSONL
    jsonl_file = None
    if write_to_file:
        os.makedirs(os.path.dirname(config['jsonl']['file_path']) or '.', exist_ok=True)
        jsonl_file = open(config['jsonl']['file_path'], mode='a', encoding='utf-8')

    # Setup Influx
    influx_client = None
    write_api = None
    if config['influxdb']['enabled']:
        influx_client = InfluxDBClient(url=config['influxdb']['url'],
                           token=config['influxdb']['token'],
                                       org=config['influxdb']['org'])
        write_api = influx_client.write_api(write_options=SYNCHRONOUS)

    # Setup Signal K
    sk_sink = None
    if config.get('signalk', {}).get('enabled', False):
        sk_sink = SignalKSink(config['signalk'])
        print("[main] Signal K export enabled")

    poll_interval = config['logging']['interval']

    # One continuous scanner feeds the registry for all batteries. Keeping it
    # running avoids the scan start/stop churn that made per-cycle discovery
    # unreliable on BlueZ.
    registry = DeviceRegistry()
    for b in config['batteries']:
        registry.register_interest(b['address'])
    scanner = BleakScanner(detection_callback=registry.detection_callback,
                           scanning_mode="active")
    await scanner.start()
    print("[main] BLE scanner started")

    print(f"[main] Starting continuous monitor (poll interval {poll_interval}s)")

    # One perpetual loop per battery keeps scanning/connecting independently, so
    # a weak battery never blocks the others and each reconnects on its own.
    tasks = [
        asyncio.create_task(
            battery_loop(config, b, write_api, jsonl_file, write_to_file,
                         write_to_stdout, registry, sk_sink, poll_interval)
        )
        for b in config['batteries']
    ]
    tasks.append(asyncio.create_task(scanner_watchdog(registry, scanner)))
    if write_api is not None:
        tasks.append(asyncio.create_task(health_loop(config, write_api)))

    try:
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()
        try:
            await scanner.stop()
        except Exception:
            pass
        if jsonl_file is not None:
            jsonl_file.close()
        if influx_client is not None:
            influx_client.close()

if __name__ == "__main__":
    args = parse_args()
    asyncio.run(main(args))
