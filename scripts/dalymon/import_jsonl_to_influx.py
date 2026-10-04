#!/usr/bin/env python3
"""
Import battery data from JSONL file to InfluxDB 2.x.
"""

import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    from influxdb_client import InfluxDBClient, Point
    from influxdb_client.client.write_api import SYNCHRONOUS
except ImportError:
    print("Error: influxdb-client package not installed")
    print("Install with: pip install influxdb-client")
    sys.exit(1)


def parse_timestamp(ts: str) -> datetime:
    """Convert ISO timestamp to datetime accepted by influxdb-client."""
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def add_numeric_field(point: Point, name: str, value: Any) -> None:
    """Add numeric field if convertible; silently skip invalid values."""
    try:
        if value is None:
            return
        point.field(name, float(value))
    except (TypeError, ValueError):
        return


def jsonl_to_influx_point(record: dict[str, Any]) -> Point:
    """Convert JSONL record to an InfluxDB Point for InfluxDB 2.x."""
    point = (
        Point("battery_status")
        .tag("battery_name", str(record.get("battery", "unknown")))
        .time(parse_timestamp(str(record["timestamp"])))
    )

    # Keep compatibility with live dalymon fields.
    add_numeric_field(point, "voltage", record.get("voltage"))
    add_numeric_field(point, "current", record.get("current"))
    add_numeric_field(point, "soc", record.get("battery_level"))
    add_numeric_field(point, "temp", record.get("temperature"))

    # Optional extra telemetry from historical JSONL.
    add_numeric_field(point, "battery_level", record.get("battery_level"))
    add_numeric_field(point, "temperature", record.get("temperature"))
    add_numeric_field(point, "power", record.get("power"))
    add_numeric_field(point, "cycle_charge", record.get("cycle_charge"))
    add_numeric_field(point, "cycle_capacity", record.get("cycle_capacity"))
    add_numeric_field(point, "delta_voltage", record.get("delta_voltage"))
    add_numeric_field(point, "cycles", record.get("cycles"))
    add_numeric_field(point, "runtime", record.get("runtime"))
    add_numeric_field(point, "cell_count", record.get("cell_count"))
    add_numeric_field(point, "temp_sensors", record.get("temp_sensors"))
    add_numeric_field(point, "problem_code", record.get("problem_code"))
    add_numeric_field(point, "balancer", record.get("balancer"))

    # Flatten per-cell voltages for easy per-cell charts in Grafana.
    cell_voltages = record.get("cell_voltages") or []
    if isinstance(cell_voltages, list):
        for idx, value in enumerate(cell_voltages, start=1):
            add_numeric_field(point, f"cell_voltage_{idx}", value)

    point.field("chrg_mosfet", bool(record.get("chrg_mosfet")))
    point.field("dischrg_mosfet", bool(record.get("dischrg_mosfet")))
    point.field("battery_charging", bool(record.get("battery_charging")))
    point.field("problem", bool(record.get("problem")))
    return point


def import_data(
    jsonl_file: Path,
    url: str = "http://localhost:8086",
    token: str = "",
    org: str = "",
    bucket: str = "battery",
    batch_size: int = 100,
) -> None:
    """Import JSONL data to InfluxDB 2.x."""
    client = InfluxDBClient(url=url, token=token, org=org)
    write_api = client.write_api(write_options=SYNCHRONOUS)

    try:
        points = []
        count = 0

        print(f"Reading data from: {jsonl_file}")
        with open(jsonl_file, "r", encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                    point = jsonl_to_influx_point(record)
                    points.append(point)
                    count += 1
                except json.JSONDecodeError as e:
                    print(f"Warning: Skipping invalid JSON line: {e}", file=sys.stderr)
                except Exception as e:
                    print(f"Warning: Error processing record: {e}", file=sys.stderr)

                if len(points) >= batch_size:
                    print(f"Writing batch of {len(points)} points...")
                    write_api.write(bucket=bucket, org=org, record=points)
                    points = []

        # Write remaining points
        if points:
            print(f"Writing final batch of {len(points)} points...")
            write_api.write(bucket=bucket, org=org, record=points)

        print(f"\nSuccessfully imported {count} records to InfluxDB bucket '{bucket}'")

    except Exception as e:
        print(f"Error connecting to InfluxDB: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        client.close()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Import battery data from JSONL to InfluxDB 2.x"
    )
    parser.add_argument(
        "jsonl_file",
        type=Path,
        help="Path to JSONL file",
    )
    parser.add_argument(
        "--url", default="http://localhost:8086", help="InfluxDB URL"
    )
    parser.add_argument(
        "--token", required=True, help="InfluxDB token"
    )
    parser.add_argument(
        "--org", required=True, help="InfluxDB organization"
    )
    parser.add_argument(
        "--bucket", default="battery", help="InfluxDB bucket (default: battery)"
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=100,
        help="Batch size for writes (default: 100)",
    )

    args = parser.parse_args()

    if not args.jsonl_file.exists():
        print(f"Error: File not found: {args.jsonl_file}", file=sys.stderr)
        sys.exit(1)

    import_data(
        args.jsonl_file,
        url=args.url,
        token=args.token,
        org=args.org,
        bucket=args.bucket,
        batch_size=args.batch_size,
    )
