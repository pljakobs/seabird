#!/usr/bin/env python3
"""Quick energy report from battery_data.jsonl."""

import json
import sys
from datetime import datetime, timezone

JSONL_PATH = "battery_data.jsonl"
HEAVY_CURRENT_A = 20      # threshold for "high load" classification
HEAVY_POWER_W   = 300
BASELINE_I_MAX  = 5       # threshold for "stationary" baseline


def load_rows(path: str) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    rows.sort(key=lambda r: r["timestamp"])
    return rows


def ts(s: str) -> datetime:
    # Support both legacy naive timestamps and newer UTC Z timestamps.
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def build_intervals(rows: list[dict]) -> list[dict]:
    intervals = []
    for a, b in zip(rows, rows[1:]):
        dt_h = (ts(b["timestamp"]) - ts(a["timestamp"])).total_seconds() / 3600
        intervals.append({
            "t0": a["timestamp"],
            "t1": b["timestamp"],
            "dt_h": dt_h,
            "power": float(a.get("power", 0.0)),
            "current": float(a.get("current", 0.0)),
        })
    return intervals


def main() -> None:
    try:
        rows = load_rows(JSONL_PATH)
    except FileNotFoundError:
        print(f"No data file found at {JSONL_PATH}", file=sys.stderr)
        sys.exit(1)

    if len(rows) < 2:
        print("Not enough data yet (need at least 2 samples).")
        return

    intervals = build_intervals(rows)

    first, last = rows[0], rows[-1]
    total_dt_h = sum(x["dt_h"] for x in intervals)
    total_wh   = first.get("cycle_capacity", 0) - last.get("cycle_capacity", 0)
    total_ah   = first.get("cycle_charge", 0)   - last.get("cycle_charge", 0)

    # Baseline (stationary load)
    baseline   = [x for x in intervals if abs(x["current"]) <= BASELINE_I_MAX]
    base_dt_h  = sum(x["dt_h"] for x in baseline)
    base_wh    = sum(x["power"] * x["dt_h"] for x in baseline)
    base_w     = base_wh / base_dt_h if base_dt_h else float("nan")

    # High-load events
    heavy = [x for x in intervals
             if abs(x["current"]) > HEAVY_CURRENT_A or abs(x["power"]) > HEAVY_POWER_W]
    heavy_dt_min = sum(x["dt_h"] for x in heavy) * 60
    heavy_wh     = sum(x["power"] * x["dt_h"] for x in heavy)

    print("=" * 52)
    print("  Battery energy report")
    print("=" * 52)
    print(f"  Samples          : {len(rows)}")
    print(f"  From             : {first['timestamp']}")
    print(f"  To               : {last['timestamp']}")
    print(f"  Duration         : {total_dt_h*60:.1f} min")
    print()
    print(f"  Total consumed   : {total_wh:.1f} Wh  /  {total_ah:.2f} Ah")
    print()
    print(f"  Stationary load  : {abs(base_w):.1f} W  (over {base_dt_h*60:.1f} min baseline)")
    print()
    print(f"  High-load events : {len(heavy)} intervals")
    print(f"  High-load total  : {heavy_dt_min:.1f} min  /  {abs(heavy_wh):.1f} Wh")
    if heavy:
        for x in heavy:
            print(f"    {x['t0']}  {x['current']:+.1f} A  {x['power']:+.1f} W  ({x['dt_h']*60:.1f} min)")
    print("=" * 52)


if __name__ == "__main__":
    main()
