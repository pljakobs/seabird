#!/usr/bin/env python3
"""Download compact marine forecasts and serve read-only AvNav planning data."""

import argparse
import bz2
from datetime import datetime, timedelta, timezone
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import tempfile
import time
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

from geographiclib.geodesic import Geodesic

UTC = timezone.utc
ROOT = Path(os.environ.get("WEATHER_DIR", "/srv/seabird/weather"))
AVNAV = os.environ.get("AVNAV_URL", "http://127.0.0.1:8088")
KNOTS = 3600 / 1852


def utc(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Time must include a UTC offset")
    return result.astimezone(UTC)


def stamp(value):
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def finite(value, name):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"Invalid {name}")
    return result


def position(lon, lat):
    lon, lat = finite(lon, "longitude"), finite(lat, "latitude")
    if not -180 <= lon <= 180 or not -90 <= lat <= 90:
        raise ValueError("Position out of range")
    return lon, lat


def load_cache(root=ROOT):
    with gzip.open(root / "current" / "forecast.json.gz", "rt") as source:
        return json.load(source)


def metadata(cache):
    now = datetime.now(UTC)
    result = {key: value for key, value in cache.items() if key != "products"}
    result["age_hours"] = round((now - utc(cache["downloaded"])).total_seconds() / 3600, 1)
    result["stale"] = result["age_hours"] > 12
    result["products"] = {}
    for name, product in cache["products"].items():
        times = sorted(frame["valid"] for frame in product["frames"])
        result["products"][name] = {
            "run": product["run"], "times": times,
            "expired": not times or utc(times[-1]) < now,
        }
    return result


def interpolate(product, lon, lat, when):
    grid = product["grid"]
    west, south, east, north = grid["bbox"]
    if not west <= lon <= east or not south <= lat <= north:
        return None
    column = min(grid["width"] - 1, int((lon - west) / (east - west) * grid["width"]))
    row = min(grid["height"] - 1, int((north - lat) / (north - south) * grid["height"]))
    index = row * grid["width"] + column
    frames = sorted(product["frames"], key=lambda frame: frame["valid"])
    if not frames or when < utc(frames[0]["valid"]) or when > utc(frames[-1]["valid"]):
        return None
    after = next(frame for frame in frames if utc(frame["valid"]) >= when)
    before = next(frame for frame in reversed(frames) if utc(frame["valid"]) <= when)
    span = (utc(after["valid"]) - utc(before["valid"])).total_seconds()
    fraction = (when - utc(before["valid"])).total_seconds() / span if span else 0
    values = {}
    for field, samples in before["values"].items():
        first, last = samples[index], after["values"][field][index]
        if first is None or last is None:
            values[field] = None
        elif field.endswith("direction_deg"):
            delta = (last - first + 180) % 360 - 180
            values[field] = (first + fraction * delta) % 360
        else:
            values[field] = round(first + fraction * (last - first), 3)
    return {"run": product["run"], "bracket": [before["valid"], after["valid"]], **values}


def point_forecast(cache, lon, lat, when):
    lon, lat = position(lon, lat)
    result = {"lon": lon, "lat": lat, "valid": stamp(when), "products": {}}
    for name, product in cache["products"].items():
        values = interpolate(product, lon, lat, when)
        if values is not None and "u_ms" in values and "v_ms" in values:
            east, north = values["u_ms"], values["v_ms"]
            if east is not None and north is not None:
                values["speed_kn"] = round(math.hypot(east, north) * KNOTS, 1)
                direction = math.degrees(math.atan2(east, north))
                values["direction_deg"] = round((direction + (180 if name == "wind" else 0)) % 360, 1)
        result["products"][name] = values
    return result


def overlay(cache, when, layer):
    if layer not in cache["products"]:
        raise ValueError("Unknown or unavailable layer")
    grid = cache["products"][layer]["grid"]
    west, south, east, north = grid["bbox"]
    features = []
    for row in range(grid["height"]):
        lat = north - (row + 0.5) * (north - south) / grid["height"]
        for column in range(grid["width"]):
            lon = west + (column + 0.5) * (east - west) / grid["width"]
            data = point_forecast(cache, lon, lat, when)["products"][layer]
            if data is None or not any(value is not None for key, value in data.items() if key not in ("run", "bracket")):
                continue
            features.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                             "properties": {"layer": layer, "valid": stamp(when), **data}})
    return {"type": "FeatureCollection", "features": features}


def route_points(path):
    tree = ET.parse(path)
    routes = tree.findall(".//{*}rte")
    if len(routes) != 1:
        raise ValueError("GPX must contain exactly one route")
    points = []
    for element in routes[0].findall("{*}rtept"):
        lon, lat = position(element.attrib["lon"], element.attrib["lat"])
        points.append({"lon": lon, "lat": lat, "name": element.findtext("{*}name", "Waypoint")})
    if len(points) < 2 or len(points) > 500:
        raise ValueError("Route must contain 2 to 500 waypoints")
    return points


def route_forecast(cache, points, departure, speed):
    speed = finite(speed, "speed")
    if not 0.5 <= speed <= 60:
        raise ValueError("Speed over ground must be 0.5 to 60 knots")
    samples, distance = [], 0.0
    previous = None
    for waypoint in points:
        lon, lat = position(waypoint["lon"], waypoint["lat"])
        if previous is not None:
            leg = Geodesic.WGS84.Inverse(previous["lat"], previous["lon"], lat, lon)
            steps = max(1, math.ceil(leg["s12"] / (5 * 1852)))
            if len(samples) + steps > 2000:
                raise ValueError("Route exceeds 2000 forecast samples; split the passage")
            for step in range(1, steps):
                offset = leg["s12"] * step / steps
                intermediate = Geodesic.WGS84.Direct(previous["lat"], previous["lon"], leg["azi1"], offset)
                travelled = distance + offset / 1852
                eta = departure + timedelta(hours=travelled / speed)
                samples.append({"name": "En route", "distance_nm": round(travelled, 1),
                                **point_forecast(cache, intermediate["lon2"], intermediate["lat2"], eta)})
            distance += leg["s12"] / 1852
        eta = departure + timedelta(hours=distance / speed)
        samples.append({"name": waypoint.get("name", "Waypoint"), "distance_nm": round(distance, 1),
                        **point_forecast(cache, lon, lat, eta)})
        previous = waypoint
    return {"departure": stamp(departure), "speed_kn": speed, "distance_nm": round(distance, 1),
            "arrival": stamp(eta), "samples": samples,
            "assumption": "Fixed speed over ground; no tidal, polar or safety routing corrections"}


def download(url, target):
    for attempt in range(3):
        try:
            with urlopen(Request(url, headers={"User-Agent": "Seabird-weather/1"}), timeout=60) as response:
                with target.open("wb") as output:
                    total = 0
                    while chunk := response.read(1024 * 1024):
                        total += len(chunk)
                        if total > 100 * 1024 * 1024:
                            raise ValueError("Weather download exceeds 100 MiB")
                        output.write(chunk)
            if url.endswith(".bz2"):
                compressed = target.with_suffix(".bz2")
                target.rename(compressed)
                with bz2.open(compressed, "rb") as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                compressed.unlink()
            return
        except Exception:
            if attempt == 2:
                raise


def dwd_url(model, run, hour, variable):
    cycle = run.strftime("%H")
    if model == "icon-d2":
        return (f"https://opendata.dwd.de/weather/nwp/icon-d2/grib/{cycle}/{variable}/"
                f"icon-d2_germany_regular-lat-lon_single-level_{run:%Y%m%d%H}_{hour:03d}_2d_{variable}.grib2.bz2")
    return (f"https://opendata.dwd.de/weather/maritime/wave_models/ewam/grib/{cycle}/{variable.lower()}/"
            f"EWAM_{variable.upper()}_{run:%Y%m%d%H}_{hour:03d}.grib2.bz2")


def discover(model, probe_hour):
    interval = 3 if model == "icon-d2" else 12
    now = datetime.now(UTC).replace(minute=0, second=0, microsecond=0)
    now = now.replace(hour=now.hour // interval * interval)
    for age in range(0, 73, interval):
        run = now - timedelta(hours=age)
        url = dwd_url(model, run, probe_hour, "u_10m" if model == "icon-d2" else "swh")
        try:
            with urlopen(Request(url, method="HEAD"), timeout=15):
                return run
        except Exception:
            continue
    raise ValueError(f"No available {model} model run")


def read_field(path, grid, element=None):
    from osgeo import gdal
    import numpy as np

    gdal.UseExceptions()
    source = gdal.Open(str(path))
    selected = None
    for band_index in range(1, source.RasterCount + 1):
        band = source.GetRasterBand(band_index)
        if element is None or band.GetMetadataItem("GRIB_ELEMENT") == element:
            selected = gdal.Translate("", source, format="MEM", bandList=[band_index])
            break
    if selected is None:
        raise ValueError(f"Missing GRIB element {element} in {path.name}")
    band = selected.GetRasterBand(1)
    valid = band.GetMetadataItem("GRIB_VALID_TIME")
    reference = band.GetMetadataItem("GRIB_REF_TIME")
    if not valid or not reference:
        raise ValueError("GRIB has no valid/reference time")
    image = gdal.Warp("", selected, format="MEM", dstSRS="EPSG:4326", outputBounds=grid["bbox"],
                      width=grid["width"], height=grid["height"], resampleAlg="near", dstNodata=-9999)
    values = image.ReadAsArray().reshape(-1)
    samples = [round(float(value), 3) if np.isfinite(value) and value != -9999 else None for value in values]
    return samples, stamp(datetime.fromtimestamp(int(valid.split()[0]), UTC)), stamp(datetime.fromtimestamp(int(reference.split()[0]), UTC))


def fetch(root=ROOT):
    bbox = [finite(value, "BBOX") for value in os.environ.get("BBOX", "8,53,16.5,60").split(",")]
    if len(bbox) != 4 or not (-180 <= bbox[0] < bbox[2] <= 180 and -90 <= bbox[1] < bbox[3] <= 90):
        raise ValueError("Invalid BBOX")
    spacing = finite(os.environ.get("GRID_STEP", "0.35"), "GRID_STEP")
    if not 0.1 <= spacing <= 2:
        raise ValueError("GRID_STEP must be 0.1 to 2 degrees")
    grid = {"bbox": bbox, "width": math.ceil((bbox[2] - bbox[0]) / spacing),
            "height": math.ceil((bbox[3] - bbox[1]) / spacing)}
    if grid["width"] * grid["height"] > 2000:
        raise ValueError("Grid exceeds 2000 points")
    hours = sorted(set(int(value) for value in os.environ.get("FORECAST_HOURS", "3,6,9,12,18,24,30,36,42,48").split(",")))
    if not hours or len(hours) > 49 or hours[0] < 0 or hours[-1] > 48:
        raise ValueError("Forecast hours must be within 0 to 48")
    root.mkdir(parents=True, exist_ok=True)
    cache = {"downloaded": stamp(datetime.now(UTC)), "products": {}, "warnings": [],
             "spatial_sampling": "Nearest coarse grid cell; linear time interpolation"}
    with tempfile.TemporaryDirectory(prefix="fetch-", dir=root) as directory:
        stage = Path(directory)
        specifications = [("wind", "icon-d2", [("u_ms", "u_10m", None), ("v_ms", "v_10m", None)]),
                          ("waves", "ewam", [("height_m", "swh", None), ("direction_deg", "mwd", None)])]
        for name, model, fields in specifications:
            try:
                run = discover(model, hours[-1])
                frames = []
                for hour in hours:
                    values, valid_time, reference_time = {}, None, None
                    for field, variable, element in fields:
                        path = stage / f"{name}-{hour:03d}-{variable}.grib2"
                        download(dwd_url(model, run, hour, variable), path)
                        samples, valid, reference = read_field(path, grid, element)
                        if utc(valid) != run + timedelta(hours=hour) or utc(reference) != run:
                            raise ValueError("Unexpected GRIB validity or model run")
                        values[field], valid_time, reference_time = samples, valid, reference
                    frames.append({"valid": valid_time, "values": values})
                cache["products"][name] = {"run": reference_time, "grid": grid, "frames": frames}
            except Exception as error:
                if name == "wind":
                    raise
                cache["warnings"].append(f"{name}: {type(error).__name__}: {error}")
        try:
            with urlopen("https://dmigw.govcloud.dk/v1/forecastdata/collections/dkss_nsbs/items?limit=20", timeout=30) as response:
                items = json.load(response)
            run = utc(max(item["properties"]["modelRun"] for item in items["features"]))
            frames = []
            for hour in hours:
                valid = run + timedelta(hours=hour)
                url = ("https://dmi-opendata.s3.eu-north-1.amazonaws.com/forecastdata/DKSS_NSBS_SF/"
                       f"DKSS_NSBS_SF_{run:%Y-%m-%dT%H%M%SZ}_{valid:%Y-%m-%dT%H%M%SZ}.grib")
                path = stage / f"currents-{hour:03d}.grib"
                download(url, path)
                values = {}
                for field, element in (("u_ms", "UOGRD"), ("v_ms", "VOGRD")):
                    samples, actual, reference = read_field(path, grid, element)
                    if utc(actual) != valid or utc(reference) != run:
                        raise ValueError("Unexpected DMI validity or model run")
                    values[field] = samples
                frames.append({"valid": stamp(valid), "values": values})
            cache["products"]["currents"] = {"run": stamp(run), "grid": grid, "frames": frames}
        except Exception as error:
            cache["warnings"].append(f"currents: {type(error).__name__}: {error}")
        with gzip.open(stage / "forecast.json.gz", "wt") as output:
            json.dump(cache, output, allow_nan=False, separators=(",", ":"))
        stage.chmod(0o755)
        generation = root / f"run-{time.time_ns()}"
        stage.rename(generation)
    temporary = root / ".current"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(generation.name, target_is_directory=True)
    temporary.replace(root / "current")
    for old in root.glob("run-*"):
        if old != generation:
            shutil.rmtree(old)
    print(json.dumps(metadata(cache), indent=2))


class WeatherHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            request = urlparse(self.path)
            path = request.path.removeprefix("/wxapi")
            query = {key: values[0] for key, values in parse_qs(request.query).items()}
            if path == "/routes":
                directory = Path(os.environ.get("AVNAV_ROUTES", "/srv/seabird/avnav/routes"))
                result = sorted(file.name for file in directory.glob("*.gpx") if file.is_file())
            else:
                cache = load_cache()
                if path == "/meta":
                    result = metadata(cache)
                elif path in ("/point", "/overlay", "/route"):
                    when = utc(query["time"])
                    if path == "/overlay":
                        result = overlay(cache, when, query.get("layer", "wind"))
                    elif path == "/point":
                        if "lon" in query and "lat" in query:
                            lon, lat = position(query["lon"], query["lat"])
                        else:
                            with urlopen(AVNAV + "/api/gps", timeout=3) as response:
                                gps = json.load(response)
                            lon, lat = position(gps["lon"], gps["lat"])
                        result = point_forecast(cache, lon, lat, when)
                    else:
                        directory = Path(os.environ.get("AVNAV_ROUTES", "/srv/seabird/avnav/routes")).resolve()
                        route = (directory / query["name"]).resolve()
                        if route.parent != directory or route.suffix.lower() != ".gpx":
                            raise ValueError("Invalid route name")
                        result = route_forecast(cache, route_points(route), when, query.get("speed", "5"))
                else:
                    self.reply(404, {"error": "Unknown endpoint"})
                    return
            self.reply(200, result)
        except (ValueError, KeyError, ET.ParseError) as error:
            self.reply(400, {"error": str(error)})
        except Exception as error:
            self.reply(503, {"error": f"Weather or position unavailable: {type(error).__name__}"})

    def reply(self, status, value):
        body = json.dumps(value, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "serve"))
    arguments = parser.parse_args()
    if arguments.command == "fetch":
        import fcntl
        ROOT.mkdir(parents=True, exist_ok=True)
        with (ROOT / ".fetch.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fetch()
    else:
        ThreadingHTTPServer(("127.0.0.1", 8089), WeatherHandler).serve_forever()