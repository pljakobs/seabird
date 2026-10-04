#!/usr/bin/env python3
"""Battery health assessment from battery_data.jsonl.

This script computes a first-pass health view and explicitly warns when
there is not enough data for robust conclusions.
"""

import json
import math
import statistics
import sys
from collections import Counter
from datetime import datetime, timezone
from typing import Any

JSONL_PATH = "battery_data.jsonl"

# Global data sufficiency gates for a robust assessment
MIN_SAMPLES_FOR_CONFIDENCE = 200
MIN_DAYS_FOR_CONFIDENCE = 7

# Metric-specific gates
MIN_STEP_EVENTS_FOR_IR = 10
MIN_POINTS_PER_SOC_BAND = 20
MIN_REST_WINDOWS = 3
STEP_CURRENT_THRESHOLD_A = 20.0
CELL_IR_REL_WARN_PCT = 20.0
CELL_IR_ABS_WARN_MOHM = 1.5


def parse_ts(ts_raw: str) -> datetime:
    """Parse both legacy naive ISO timestamps and UTC Z timestamps."""
    dt = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def load_rows(path: str) -> list[dict[str, Any]]:
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            row["_ts"] = parse_ts(row["timestamp"])
            rows.append(row)
    rows.sort(key=lambda r: r["_ts"])
    return rows


def median_or_nan(values: list[float]) -> float:
    if not values:
        return float("nan")
    return statistics.median(values)


def fmt_float(value: float, digits: int = 3, unit: str = "") -> str:
    if value is None or not math.isfinite(value):
        return "n/a"
    return f"{value:.{digits}f}{unit}"


def assess(rows: list[dict[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {
        "warnings": [],
        "remarks": [],
        "metrics": {},
    }

    if len(rows) < 2:
        out["warnings"].append("Not enough data: need at least 2 samples.")
        return out

    start = rows[0]["_ts"]
    end = rows[-1]["_ts"]
    span_h = (end - start).total_seconds() / 3600.0
    span_days = span_h / 24.0

    out["metrics"]["samples"] = len(rows)
    out["metrics"]["time_span_hours"] = span_h
    out["metrics"]["time_span_days"] = span_days

    if len(rows) < MIN_SAMPLES_FOR_CONFIDENCE:
        out["warnings"].append(
            f"Insufficient sample count for high-confidence health scoring: "
            f"{len(rows)} < {MIN_SAMPLES_FOR_CONFIDENCE}."
        )

    if span_days < MIN_DAYS_FOR_CONFIDENCE:
        out["warnings"].append(
            f"Insufficient time span for trend-based health scoring: "
            f"{span_days:.2f}d < {MIN_DAYS_FOR_CONFIDENCE}d."
        )

    # ---------- Voltage drop under load: pack/cell resistance proxy ----------
    step_pack_mohm: list[float] = []
    step_cell_mohm: list[float] = []
    step_cell_mohm_by_cell: dict[int, list[float]] = {}

    for prev, cur in zip(rows, rows[1:]):
        i0 = float(prev.get("current", 0.0))
        i1 = float(cur.get("current", 0.0))
        di = i1 - i0
        if abs(di) < STEP_CURRENT_THRESHOLD_A:
            continue

        v0 = float(prev.get("voltage", 0.0))
        v1 = float(cur.get("voltage", 0.0))
        dv = v1 - v0
        if abs(di) > 1e-9:
            step_pack_mohm.append(abs(dv / di) * 1000.0)

        cv0 = prev.get("cell_voltages") or []
        cv1 = cur.get("cell_voltages") or []
        if isinstance(cv0, list) and isinstance(cv1, list) and len(cv0) == len(cv1) and len(cv0) > 0:
            for idx, (a, b) in enumerate(zip(cv0, cv1), start=1):
                try:
                    cdv = float(b) - float(a)
                    ir = abs(cdv / di) * 1000.0
                    step_cell_mohm.append(ir)
                    step_cell_mohm_by_cell.setdefault(idx, []).append(ir)
                except (TypeError, ValueError, ZeroDivisionError):
                    continue

    out["metrics"]["step_events"] = len(step_pack_mohm)
    out["metrics"]["pack_ir_proxy_median_mohm"] = median_or_nan(step_pack_mohm)
    out["metrics"]["cell_ir_proxy_median_mohm"] = median_or_nan(step_cell_mohm)
    per_cell_ir_medians = {
        idx: median_or_nan(vals) for idx, vals in sorted(step_cell_mohm_by_cell.items())
    }
    out["metrics"]["cell_ir_proxy_median_mohm_by_cell"] = per_cell_ir_medians

    if len(step_pack_mohm) < MIN_STEP_EVENTS_FOR_IR:
        out["warnings"].append(
            f"Insufficient load-step events for robust resistance trend: "
            f"{len(step_pack_mohm)} < {MIN_STEP_EVENTS_FOR_IR}."
        )

    # Heuristic per-cell IR remarks (directional, not absolute lab values)
    finite_cell_medians = [v for v in per_cell_ir_medians.values() if math.isfinite(v)]
    if finite_cell_medians:
        fleet_median = statistics.median(finite_cell_medians)
        for idx, val in per_cell_ir_medians.items():
            if not math.isfinite(val):
                continue
            if val > CELL_IR_ABS_WARN_MOHM:
                out["remarks"].append(
                    f"Cell {idx} IR proxy is high in absolute terms ({val:.3f} mOhm > {CELL_IR_ABS_WARN_MOHM:.1f} mOhm)."
                )
            if fleet_median > 0:
                rel_pct = (val / fleet_median - 1.0) * 100.0
                if rel_pct > CELL_IR_REL_WARN_PCT:
                    out["remarks"].append(
                        f"Cell {idx} IR proxy is {rel_pct:.1f}% above cell-median baseline ({fleet_median:.3f} mOhm)."
                    )

    # ---------- Cell imbalance by SOC band ----------
    band_values: dict[str, list[float]] = {"low": [], "mid": [], "high": []}
    for r in rows:
        try:
            soc = float(r.get("battery_level", float("nan")))
            d = float(r.get("delta_voltage", float("nan")))
        except (TypeError, ValueError):
            continue
        if not math.isfinite(soc) or not math.isfinite(d):
            continue

        if soc < 30:
            band_values["low"].append(d)
        elif soc < 80:
            band_values["mid"].append(d)
        else:
            band_values["high"].append(d)

    out["metrics"]["delta_v_median_low_soc_v"] = median_or_nan(band_values["low"])
    out["metrics"]["delta_v_median_mid_soc_v"] = median_or_nan(band_values["mid"])
    out["metrics"]["delta_v_median_high_soc_v"] = median_or_nan(band_values["high"])

    for band, values in band_values.items():
        if len(values) < MIN_POINTS_PER_SOC_BAND:
            out["warnings"].append(
                f"Insufficient points for {band} SOC imbalance assessment: "
                f"{len(values)} < {MIN_POINTS_PER_SOC_BAND}."
            )

    # ---------- High-SOC first-hit behavior (weak/strong cell dominance) ----------
    high_soc_rows = [r for r in rows if float(r.get("battery_level", 0.0)) >= 90.0]
    low_cell_counter: Counter[int] = Counter()
    high_cell_counter: Counter[int] = Counter()

    for r in high_soc_rows:
        cell_vs = r.get("cell_voltages") or []
        if not isinstance(cell_vs, list) or len(cell_vs) == 0:
            continue
        try:
            vals = [float(v) for v in cell_vs]
        except (TypeError, ValueError):
            continue
        low_idx = min(range(len(vals)), key=lambda i: vals[i])
        high_idx = max(range(len(vals)), key=lambda i: vals[i])
        low_cell_counter[low_idx + 1] += 1
        high_cell_counter[high_idx + 1] += 1

    out["metrics"]["high_soc_samples"] = len(high_soc_rows)
    out["metrics"]["most_frequent_low_cell_at_high_soc"] = (
        low_cell_counter.most_common(1)[0] if low_cell_counter else None
    )
    out["metrics"]["most_frequent_high_cell_at_high_soc"] = (
        high_cell_counter.most_common(1)[0] if high_cell_counter else None
    )

    if len(high_soc_rows) < MIN_POINTS_PER_SOC_BAND:
        out["warnings"].append(
            "Insufficient high-SOC samples for robust first-hit behavior analysis."
        )

    # ---------- Temperature response under load ----------
    low_load_t: list[float] = []
    high_load_t: list[float] = []

    for r in rows:
        try:
            i = abs(float(r.get("current", 0.0)))
            t = float(r.get("temperature", float("nan")))
        except (TypeError, ValueError):
            continue
        if not math.isfinite(t):
            continue
        if i <= 5:
            low_load_t.append(t)
        if i >= 20:
            high_load_t.append(t)

    med_low_t = median_or_nan(low_load_t)
    med_high_t = median_or_nan(high_load_t)
    out["metrics"]["temp_median_low_load_c"] = med_low_t
    out["metrics"]["temp_median_high_load_c"] = med_high_t
    out["metrics"]["temp_rise_proxy_c"] = (
        med_high_t - med_low_t
        if math.isfinite(med_low_t) and math.isfinite(med_high_t)
        else float("nan")
    )

    if len(high_load_t) < MIN_POINTS_PER_SOC_BAND:
        out["warnings"].append(
            "Insufficient high-load temperature points for thermal trend confidence."
        )

    # ---------- Self-discharge / rest drift windows ----------
    # Use windows where |I| <= 1A continuously for >=30 minutes.
    rest_windows = 0
    rest_drifts = []
    run_start = None
    run_rows: list[dict[str, Any]] = []

    for r in rows:
        i = abs(float(r.get("current", 0.0)))
        if i <= 1.0:
            if run_start is None:
                run_start = r["_ts"]
                run_rows = [r]
            else:
                run_rows.append(r)
        else:
            if run_start is not None and run_rows:
                dur_min = (run_rows[-1]["_ts"] - run_start).total_seconds() / 60.0
                if dur_min >= 30 and len(run_rows) >= 2:
                    rest_windows += 1
                    try:
                        v0 = float(run_rows[0].get("voltage", float("nan")))
                        v1 = float(run_rows[-1].get("voltage", float("nan")))
                        if math.isfinite(v0) and math.isfinite(v1):
                            rest_drifts.append(v1 - v0)
                    except (TypeError, ValueError):
                        pass
            run_start = None
            run_rows = []

    out["metrics"]["rest_windows"] = rest_windows
    out["metrics"]["rest_voltage_drift_median_v"] = median_or_nan(rest_drifts)

    if rest_windows < MIN_REST_WINDOWS:
        out["warnings"].append(
            f"Insufficient rest windows for self-discharge assessment: "
            f"{rest_windows} < {MIN_REST_WINDOWS}."
        )

    # ---------- Fault / protection events ----------
    fault_rows = [
        r for r in rows
        if bool(r.get("problem", False)) or int(r.get("problem_code", 0)) != 0
    ]
    out["metrics"]["fault_events"] = len(fault_rows)

    # ---------- Capacity trend confidence gate ----------
    soc_vals = [float(r.get("battery_level", float("nan"))) for r in rows]
    soc_vals = [x for x in soc_vals if math.isfinite(x)]
    if soc_vals:
        soc_span = max(soc_vals) - min(soc_vals)
    else:
        soc_span = float("nan")
    out["metrics"]["soc_span_pct"] = soc_span

    if not math.isfinite(soc_span) or soc_span < 30:
        out["warnings"].append(
            "SOC window is too narrow for robust capacity retention assessment (need wider cycling)."
        )

    return out


def print_assessment(result: dict[str, Any]) -> None:
    m = result["metrics"]
    w = result["warnings"]
    r = result.get("remarks", [])

    print("=" * 64)
    print("Battery Health Assessment (preliminary)")
    print("=" * 64)
    print(f"Samples: {m.get('samples', 'n/a')}")
    print(f"Time span: {fmt_float(m.get('time_span_hours', float('nan')), 2, ' h')} "
          f"({fmt_float(m.get('time_span_days', float('nan')), 2, ' d')})")
    print()

    print("Resistance proxy (load-step based):")
    print(f"  Step events: {m.get('step_events', 0)}")
    print(f"  Pack IR proxy median: {fmt_float(m.get('pack_ir_proxy_median_mohm', float('nan')), 3, ' mOhm')}")
    print(f"  Cell IR proxy median: {fmt_float(m.get('cell_ir_proxy_median_mohm', float('nan')), 3, ' mOhm')}")
    per_cell = m.get("cell_ir_proxy_median_mohm_by_cell", {})
    if per_cell:
        print("  Per-cell IR proxy medians:")
        for idx, val in sorted(per_cell.items()):
            print(f"    Cell {idx}: {fmt_float(val, 3, ' mOhm')}")
    print()

    print("Cell imbalance by SOC band (delta_voltage median):")
    print(f"  Low SOC (<30%):  {fmt_float(m.get('delta_v_median_low_soc_v', float('nan')), 4, ' V')}")
    print(f"  Mid SOC (30-80%): {fmt_float(m.get('delta_v_median_mid_soc_v', float('nan')), 4, ' V')}")
    print(f"  High SOC (>=80%): {fmt_float(m.get('delta_v_median_high_soc_v', float('nan')), 4, ' V')}")
    print()

    print("High-SOC first-hit behavior:")
    print(f"  High-SOC samples: {m.get('high_soc_samples', 0)}")
    print(f"  Most frequent low cell: {m.get('most_frequent_low_cell_at_high_soc', None)}")
    print(f"  Most frequent high cell: {m.get('most_frequent_high_cell_at_high_soc', None)}")
    print()

    print("Thermal response:")
    print(f"  Median temp low load: {fmt_float(m.get('temp_median_low_load_c', float('nan')), 2, ' C')}")
    print(f"  Median temp high load: {fmt_float(m.get('temp_median_high_load_c', float('nan')), 2, ' C')}")
    print(f"  Temp rise proxy: {fmt_float(m.get('temp_rise_proxy_c', float('nan')), 2, ' C')}")
    print()

    print("Rest/self-discharge and faults:")
    print(f"  Rest windows: {m.get('rest_windows', 0)}")
    print(f"  Rest voltage drift median: {fmt_float(m.get('rest_voltage_drift_median_v', float('nan')), 4, ' V')}")
    print(f"  Fault events: {m.get('fault_events', 0)}")
    print(f"  SOC span: {fmt_float(m.get('soc_span_pct', float('nan')), 2, ' %')}")
    print()

    if w:
        print("Warnings (insufficient data/confidence):")
        for msg in w:
            print(f"  - {msg}")
    else:
        print("No data sufficiency warnings. Confidence is moderate/high.")

    if r:
        print()
        print("Remarks (heuristic checks):")
        for msg in r:
            print(f"  - {msg}")

    print("=" * 64)


def main() -> None:
    try:
        rows = load_rows(JSONL_PATH)
    except FileNotFoundError:
        print(f"No data file found at {JSONL_PATH}", file=sys.stderr)
        sys.exit(1)

    result = assess(rows)
    print_assessment(result)


if __name__ == "__main__":
    main()
