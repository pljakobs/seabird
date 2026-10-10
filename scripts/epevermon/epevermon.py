"""Epever MPPT monitor: read-only Modbus, JSONL, InfluxDB and Signal K."""

import argparse
import asyncio
import json
import logging
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol

from protocol import Controller, ProtocolError, Scalar, poll

LOG = logging.getLogger("epevermon")


class Sink(Protocol):
    async def send(self, name: str, data: dict) -> None: ...


def load_config(path: str) -> tuple[dict, list[Controller]]:
    with open(path, "rb") as file:
        config = tomllib.load(file)
    controllers = [Controller(**item) for item in config["controllers"]]
    if not controllers or len({item.id for item in controllers}) != len(controllers):
        raise ValueError("configure at least one controller with unique ids")
    for section in ("jsonl", "influxdb", "signalk"):
        if not isinstance(config.get(section, {}).get("enabled", False), bool):
            raise ValueError(f"{section}.enabled must be a boolean")
    if config.get("influxdb", {}).get("enabled", False):
        for key in ("url", "token", "org", "bucket"):
            if not config["influxdb"].get(key) or "REPLACE_WITH_" in config["influxdb"][key]:
                raise ValueError(f"configure influxdb.{key} before enabling InfluxDB")
    if config.get("jsonl", {}).get("enabled", False) and not config["jsonl"].get("file_path"):
        raise ValueError("configure jsonl.file_path before enabling JSONL")
    return config, controllers


def write_jsonl(path: str, record: dict) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("a", encoding="utf-8") as file:
        file.write(json.dumps(record, ensure_ascii=True, allow_nan=False) + "\n")


def write_influx(config: dict, controller: Controller, timestamp: datetime, data: dict[str, Scalar]) -> None:
    from influxdb_client import InfluxDBClient, Point
    from influxdb_client.client.write_api import SYNCHRONOUS

    point = Point("solar_status").tag("controller_id", controller.id).tag("controller_name", controller.name)
    point.time(timestamp)
    for key, value in data.items():
        # Keep numeric telemetry types stable across zero/nonzero readings.
        point.field(key, value if isinstance(value, (bool, str)) else float(value))
    with InfluxDBClient(url=config["url"], token=config["token"], org=config["org"], timeout=10_000) as client:
        with client.write_api(write_options=SYNCHRONOUS) as writer:
            writer.write(bucket=config["bucket"], org=config["org"], record=point)


async def export(config: dict, controller: Controller, data: dict[str, Scalar], sink: Sink | None) -> None:
    timestamp = datetime.now(timezone.utc)
    record = {"timestamp": timestamp.isoformat().replace("+00:00", "Z"),
              "controller": controller.name, "controller_id": controller.id, **data}
    # A failed sink must not suppress the other independent exports.
    if config.get("jsonl", {}).get("enabled", False):
        try:
            await asyncio.to_thread(write_jsonl, config["jsonl"]["file_path"], record)
        except OSError:
            LOG.exception("[%s] JSONL export failed", controller.name)
    if config.get("influxdb", {}).get("enabled", False):
        from influxdb_client.rest import ApiException
        from urllib3.exceptions import HTTPError

        try:
            await asyncio.to_thread(write_influx, config["influxdb"], controller, timestamp, data)
        except (ApiException, HTTPError, OSError):
            LOG.exception("[%s] InfluxDB export failed", controller.name)
    if sink is not None:
        await sink.send(controller.id, data)


async def controller_loop(config: dict, controller: Controller, sink: Sink | None) -> None:
    backoff = 5.0
    while True:
        try:
            data = await asyncio.to_thread(poll, controller)
        except (OSError, ProtocolError) as error:
            LOG.error("[%s] Read failed (%s:%s, %s, slave %s): %s; retry in %ss",
                      controller.name, controller.host, controller.port, controller.transport,
                      controller.slave, error, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60)
            continue
        backoff = 5
        await export(config, controller, data, sink)
        LOG.info("[%s] PV %.2f W, charge %.2f A, %s; faults: %s", controller.name,
                 data["pv_power"], data["charge_current"], data["charging_state"], data["faults"])
        await asyncio.sleep(controller.interval)


async def monitor(config: dict, controllers: list[Controller]) -> None:
    sink: Sink | None = None
    if config.get("signalk", {}).get("enabled", False):
        from signalk_sink import websockets
        from solar_sink import SolarSink

        if websockets is None:
            raise RuntimeError("Signal K is enabled but websockets is not installed; run the installer")
        sink = SolarSink(config["signalk"], log=lambda text: LOG.info("%s", text))
        await sink.ensure_access()
    await asyncio.gather(*(controller_loop(config, controller, sink) for controller in controllers))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/epevermon.conf")
    parser.add_argument("--check-config", action="store_true", help="Validate configuration without network access")
    parser.add_argument("--once", action="store_true", help="Read once, print JSON, and exit without exporting")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config, controllers = load_config(args.config)
    if args.check_config:
        return
    if args.once:
        for controller in controllers:
            print(json.dumps({"controller_id": controller.id, **poll(controller)}, allow_nan=False))
        return
    asyncio.run(monitor(config, controllers))


if __name__ == "__main__":
    main()
