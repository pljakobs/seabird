import math
import os
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from influxdb_client import InfluxDBClient
from scipy.signal import savgol_filter

# ==========================================
# CONFIGURATION
# ==========================================
#INFLUX_URL = "http://100.64.0.1:8086"
INFLUX_URL = "http://192.168.42.1:8086"
INFLUX_TOKEN = os.environ["INFLUX_TOKEN"]
INFLUX_ORG = "seabird"

# MMSI and target time range
VESSEL_MMSI = "vessels.urn:mrn:imo:mmsi:211863050"
TIME_RANGE = "-10d"  # Pull past 90 days of sailing data
WINDOW_PERIOD = "10s"  # High enough resolution to capture steady-state dynamics

# Performance filtering thresholds
MIN_SOG_KTS = 0.5  # Exclude stationary or drifting
THEORETICAL_HULL_SPEED = 6.99  # Theoretical displacement hull speed (kts)
MAX_SOG_KTS = 7.50  # Filter buffer to eliminate GPS anomalies without flattening 90th percentile
MIN_AWS_KTS = 1.0  # Ignore near-calm conditions
#MAX_ACCEL = 0.15  # Max delta SOG (kts) per second to eliminate acceleration/motoring spikes
MAX_ACCEL = 0.1  # Max delta SOG (kts) per second to eliminate acceleration/motoring spikes

# Polar binning & performance extraction
TWS_BINS = [6, 8, 10, 12, 14, 18, 22]  # Target True Wind Speeds (knots) for plot lines
TWA_BIN_WIDTH = 5  # Group TWA into 5-degree increments
QUANTILE_PERFORMANCE = 0.90  # 90th percentile represents optimal sail trim envelope

# ==========================================
# FLUX QUERY
# ==========================================
FLUX_QUERY = f"""
from(bucket: "SignalK")
  |> range(start: {TIME_RANGE})
  |> filter(fn: (r) => r["context"] == "{VESSEL_MMSI}")
    |> filter(fn: (r) =>
      (r["_measurement"] == "navigation.position" and (r["_field"] == "lat" or r["_field"] == "lon")) or
      (r["_measurement"] == "navigation.speedOverGround" and r["_field"] == "value") or
      (r["_measurement"] == "environment.wind.speedApparent" and r["_field"] == "value") or
      (r["_measurement"] == "environment.wind.angleApparent" and r["_field"] == "value")
  )
  |> aggregateWindow(every: {WINDOW_PERIOD}, fn: mean, createEmpty: false)
  |> pivot(rowKey:["_time"], columnKey: ["_measurement", "_field"], valueColumn: "_value")
"""


def fetch_data() -> pd.DataFrame:
    print("Querying InfluxDB...")
    client = InfluxDBClient(
        url=INFLUX_URL, token=INFLUX_TOKEN, org=INFLUX_ORG, timeout=30000
    )
    query_api = client.query_api()

    tables = query_api.query_data_frame(query=FLUX_QUERY)
    client.close()

    if isinstance(tables, list):
        df = pd.concat(tables)
    else:
        df = tables

    col_map = {
        "navigation.speedOverGround_value": "sog_ms",
        "environment.wind.speedApparent_value": "aws_ms",
        "environment.wind.angleApparent_value": "awa_rad",
    }
    df = df.rename(columns=col_map)
    return df


def process_telemetry(df: pd.DataFrame) -> pd.DataFrame:
    print("Processing vector conversions and applying sanity filters...")

    if "_time" in df.columns:
        df = df.sort_values("_time").reset_index(drop=True)

    print(f"Raw input row count: {len(df)}")

    target_cols = [c for c in ["sog_ms", "aws_ms", "awa_rad"] if c in df.columns]
    df[target_cols] = df[target_cols].ffill(limit=3)

    df = df.dropna(subset=["sog_ms", "aws_ms", "awa_rad"]).copy()
    print(f"Rows with complete telemetry (after ffill): {len(df)}")

    if df.empty:
        return df

    df["sog_kts"] = df["sog_ms"] * 1.94384
    df["aws_kts"] = df["aws_ms"] * 1.94384

    awa_deg = np.degrees(df["awa_rad"])
    df["awa_deg"] = (awa_deg + 180) % 360 - 180
    df["awa_abs"] = np.abs(df["awa_deg"])

    awa_rad_abs = np.radians(df["awa_abs"])
    df["tws_kts"] = np.sqrt(
        df["aws_kts"] ** 2
        + df["sog_kts"] ** 2
        - 2 * df["aws_kts"] * df["sog_kts"] * np.cos(awa_rad_abs)
    )

    cos_twa = (df["aws_kts"] * np.cos(awa_rad_abs) - df["sog_kts"]) / df["tws_kts"]
    cos_twa = np.clip(cos_twa, -1.0, 1.0)
    df["twa_deg"] = np.degrees(np.arccos(cos_twa))

    valid_mask = (
        (df["sog_kts"] >= MIN_SOG_KTS)
        & (df["sog_kts"] <= MAX_SOG_KTS)
        & (df["aws_kts"] >= MIN_AWS_KTS)
        & (df["twa_deg"] >= 20.0)
        & (df["twa_deg"] <= 180.0)
    )
    df = df[valid_mask].copy()

    df["dt"] = df["_time"].diff().dt.total_seconds().fillna(10.0)
    df["dsog_dt"] = (df["sog_kts"].diff() / df["dt"]).abs()
    df = df[df["dsog_dt"] <= MAX_ACCEL].copy()

    print(f"Rows retained after velocity & acceleration bounds: {len(df)}")
    return df


def build_polar_surface_smoothed(df: pd.DataFrame) -> dict:
    polar_curves = {}

    for target_tws in TWS_BINS:
        window = 2.5 if target_tws <= 10 else 3.5
        tws_mask = (df["tws_kts"] >= target_tws - window) & (
            df["tws_kts"] <= target_tws + window
        )
        sub_df = df[tws_mask].copy()

        sub_df = sub_df[sub_df["twa_deg"] >= 25.0]

        if sub_df.empty:
            print(f"  [TWS {target_tws} kts] No telemetry points in wind band.")
            continue

        sub_df["twa_bin"] = (
            np.floor(sub_df["twa_deg"] / TWA_BIN_WIDTH) * TWA_BIN_WIDTH
        ).astype(float)

        bin_counts = sub_df.groupby("twa_bin")["sog_kts"].count()
        valid_bins = bin_counts[bin_counts >= 1].index
        sub_df = sub_df[sub_df["twa_bin"].isin(valid_bins)]

        if sub_df.empty:
            print(f"  [TWS {target_tws} kts] Insufficient samples per bin.")
            continue

        bin_stats = (
            sub_df.groupby("twa_bin")["sog_kts"]
            .quantile(QUANTILE_PERFORMANCE)
            .reset_index()
        )
        bin_stats["twa_bin"] = bin_stats["twa_bin"].astype(float)

        min_angle = bin_stats["twa_bin"].min()
        max_angle = bin_stats["twa_bin"].max()

        if pd.isna(min_angle) or pd.isna(max_angle):
            print(f"  [TWS {target_tws} kts] Angle bounds evaluation failed.")
            continue

        all_angles = pd.DataFrame(
            {"twa_bin": np.arange(min_angle, max_angle + TWA_BIN_WIDTH, TWA_BIN_WIDTH, dtype=float)}
        )

        merged = pd.merge(all_angles, bin_stats, on="twa_bin", how="left")
        merged["sog_kts"] = merged["sog_kts"].interpolate(method="linear").bfill().ffill()

        # Enforce theoretical displacement hull speed cap
        merged["sog_kts"] = np.minimum(merged["sog_kts"], THEORETICAL_HULL_SPEED)

        if len(merged) >= 5:
            win_len = min(5, len(merged) if len(merged) % 2 != 0 else len(merged) - 1)
            merged["sog_kts"] = savgol_filter(merged["sog_kts"], window_length=win_len, polyorder=2)

        merged["sog_kts"] = np.minimum(merged["sog_kts"], THEORETICAL_HULL_SPEED)

        print(f"  [TWS {target_tws} kts] Valid polar curve generated ({len(merged)} bins).")
        polar_curves[target_tws] = merged

    # Monotonicity check across TWS curves
    sorted_tws = [t for t in sorted(polar_curves.keys()) if not polar_curves[t].empty]
    for i in range(1, len(sorted_tws)):
        lower_tws, higher_tws = sorted_tws[i - 1], sorted_tws[i]
        df_low, df_high = polar_curves[lower_tws], polar_curves[higher_tws]

        merged = pd.merge(df_high, df_low, on="twa_bin", suffixes=("_high", "_low"))
        if not merged.empty:
            merged["sog_kts_high"] = np.maximum(merged["sog_kts_high"], merged["sog_kts_low"])
            polar_curves[higher_tws].loc[
                polar_curves[higher_tws]["twa_bin"].isin(merged["twa_bin"]),
                "sog_kts",
            ] = merged["sog_kts_high"].values

    return polar_curves


def plot_polar(polar_curves: dict, raw_df: pd.DataFrame):
    print("Generating Polar Diagram...")
    fig, ax = plt.subplots(figsize=(10, 10), subplot_kw={"projection": "polar"})

    ax.set_theta_zero_location("N")
    ax.set_theta_direction(-1)
    ax.set_thetamin(0)
    ax.set_thetamax(180)

    active_curves = {tws: df for tws, df in polar_curves.items() if not df.empty}

    if not active_curves:
        print("Warning: No binned curves generated. Plotting raw scatter telemetry.")
        angles_rad = np.radians(raw_df["twa_deg"])
        sog_values = raw_df["sog_kts"]
        ax.scatter(angles_rad, sog_values, s=2, alpha=0.3, color="blue", label="Raw Telemetry")
    else:
        colors = plt.cm.plasma(np.linspace(0.1, 0.85, len(active_curves)))
        for (tws, data), color in zip(active_curves.items(), colors):
            angles_rad = np.radians(data["twa_bin"])
            sog_values = data["sog_kts"]

            sorted_indices = np.argsort(angles_rad)
            angles_rad = angles_rad.iloc[sorted_indices]
            sog_values = sog_values.iloc[sorted_indices]

            ax.plot(
                angles_rad,
                sog_values,
                marker="o",
                markersize=4,
                linewidth=2,
                color=color,
                label=f"{tws} kts TWS",
            )

    ax.set_title(
        f"Estimated Polar Diagram (MMSI 211863050)\n{QUANTILE_PERFORMANCE*100:.0f}th Percentile Smoothed Performance (Cap: {THEORETICAL_HULL_SPEED} kts)",
        pad=20,
        fontsize=14,
        weight="bold",
    )
    ax.set_xlabel("Boat Speed (Knots)", labelpad=15, fontsize=11)
    ax.set_rmax(THEORETICAL_HULL_SPEED + 0.5)
    ax.set_thetagrids(
        np.arange(0, 185, 15),
        labels=[f"{deg}°" for deg in range(0, 185, 15)],
    )

    ax.legend(loc="upper right", bbox_to_anchor=(1.25, 1.1), title="True Wind")
    ax.grid(True, linestyle="--", alpha=0.6)

    plt.tight_layout()
    plt.savefig("vessel_polar_diagram_smoothed.png", dpi=300)
    print("Saved plot to 'vessel_polar_diagram_smoothed.png'")
    plt.show()


def plot_vmg(polar_curves: dict):
    """Calculates upwind/downwind VMG across TWS curves and plots VMG vs.

    TWS and Target TWA vs. TWS.
    """
    print("Calculating VMG and generating target performance charts...")
    vmg_results = []

    for tws, df in polar_curves.items():
        if df.empty:
            continue

        df_calc = df.copy()
        twa_rad = np.radians(df_calc["twa_bin"])

        # Upwind VMG = SOG * cos(TWA)
        df_calc["vmg_up"] = df_calc["sog_kts"] * np.cos(twa_rad)

        # Downwind VMG = SOG * -cos(TWA)
        df_calc["vmg_dn"] = df_calc["sog_kts"] * -np.cos(twa_rad)

        upwind_df = df_calc[(df_calc["twa_bin"] >= 28) & (df_calc["twa_bin"] <= 70)]
        downwind_df = df_calc[(df_calc["twa_bin"] >= 110) & (df_calc["twa_bin"] <= 180)]

        if not upwind_df.empty:
            best_up = upwind_df.loc[upwind_df["vmg_up"].idxmax()]
            opt_up_vmg = best_up["vmg_up"]
            opt_up_twa = best_up["twa_bin"]
            opt_up_sog = best_up["sog_kts"]
        else:
            opt_up_vmg, opt_up_twa, opt_up_sog = np.nan, np.nan, np.nan

        if not downwind_df.empty:
            best_dn = downwind_df.loc[downwind_df["vmg_dn"].idxmax()]
            opt_dn_vmg = best_dn["vmg_dn"]
            opt_dn_twa = best_dn["twa_bin"]
            opt_dn_sog = best_dn["sog_kts"]
        else:
            opt_dn_vmg, opt_dn_twa, opt_dn_sog = np.nan, np.nan, np.nan

        vmg_results.append(
            {
                "tws_kts": tws,
                "opt_up_vmg": opt_up_vmg,
                "opt_up_twa": opt_up_twa,
                "opt_up_sog": opt_up_sog,
                "opt_dn_vmg": opt_dn_vmg,
                "opt_dn_twa": opt_dn_twa,
                "opt_dn_sog": opt_dn_sog,
            }
        )

    vmg_df = pd.DataFrame(vmg_results)

    if vmg_df.empty:
        print("Warning: Insufficient curve data to extract VMG targets.")
        return

    print("\n=== OPTIMAL TARGET VMG SUMMARY TABLE ===")
    print(vmg_df.to_string(index=False))

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))

    # Panel 1: Optimal VMG Speeds
    ax1.plot(
        vmg_df["tws_kts"],
        vmg_df["opt_up_vmg"],
        "o-",
        color="navy",
        linewidth=2,
        label="Optimal Upwind VMG",
    )
    ax1.plot(
        vmg_df["tws_kts"],
        vmg_df["opt_dn_vmg"],
        "o--",
        color="crimson",
        linewidth=2,
        label="Optimal Downwind VMG",
    )
    ax1.set_title("Optimal VMG vs. True Wind Speed", fontsize=12, weight="bold")
    ax1.set_xlabel("True Wind Speed (Knots)", fontsize=10)
    ax1.set_ylabel("VMG (Knots)", fontsize=10)
    ax1.grid(True, linestyle="--", alpha=0.6)
    ax1.legend()

    # Panel 2: Target TWAs
    ax2.plot(
        vmg_df["tws_kts"],
        vmg_df["opt_up_twa"],
        "s-",
        color="navy",
        linewidth=2,
        label="Target Upwind TWA",
    )
    ax2.plot(
        vmg_df["tws_kts"],
        vmg_df["opt_dn_twa"],
        "s--",
        color="crimson",
        linewidth=2,
        label="Target Downwind TWA",
    )
    ax2.set_title(
        "Target True Wind Angle (TWA) vs. TWS", fontsize=12, weight="bold"
    )
    ax2.set_xlabel("True Wind Speed (Knots)", fontsize=10)
    ax2.set_ylabel("Target TWA (Degrees)", fontsize=10)
    ax2.grid(True, linestyle="--", alpha=0.6)
    ax2.legend()

    plt.tight_layout()
    plt.savefig("vessel_vmg_targets.png", dpi=300)
    print("Saved VMG target plot to 'vessel_vmg_targets.png'")
    plt.show()


def main():
    raw_df = fetch_data()
    if raw_df.empty:
        print("No data returned from query.")
        return

    processed_df = process_telemetry(raw_df)
    if processed_df.empty:
        print("Data empty after filtering.")
        return

    polar_curves = build_polar_surface_smoothed(processed_df)
    plot_polar(polar_curves, processed_df)
    plot_vmg(polar_curves)


if __name__ == "__main__":
    main()
