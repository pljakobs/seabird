import math
import os
import xml.etree.ElementTree as ET
import gpxpy
import gpxpy.gpx
from influxdb_client import InfluxDBClient

INFLUX_URL = "http://100.64.0.1:8086"
INFLUX_TOKEN = os.environ["INFLUX_TOKEN"]
INFLUX_ORG = "seabird"

FLUX_QUERY ="""
from(bucket: "SignalK")
  |> range(start: -120d)
  |> filter(fn: (r) => r["context"] == "vessels.urn:mrn:imo:mmsi:211863050")
    |> filter(fn: (r) =>
      (r["_measurement"] == "navigation.position" and (r["_field"] == "lat" or r["_field"] == "lon")) or
      (r["_measurement"] == "navigation.speedOverGround" and r["_field"] == "value") or
      (r["_measurement"] == "navigation.course.calcValues.bearingMagnetic" and r["_field"] == "value") or
      (r["_measurement"] == "environment.wind.speedApparent" and r["_field"] == "value") or
      (r["_measurement"] == "environment.wind.angleApparent" and r["_field"] == "value")
  )
  |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
  |> pivot(rowKey:["_time"], columnKey: ["_measurement", "_field"], valueColumn: "_value")
"""
def generate_gpx_with_telemetry(output_filename="vessel_track_full.gpx"):
    client = InfluxDBClient(url=INFLUX_URL, token=INFLUX_TOKEN, org=INFLUX_ORG)
    query_api = client.query_api()

    gpx = gpxpy.gpx.GPX()
    gpx_track = gpxpy.gpx.GPXTrack(name="Vessel Track - MMSI 211863050")
    gpx.tracks.append(gpx_track)
    gpx_segment = gpxpy.gpx.GPXTrackSegment()
    gpx_track.segments.append(gpx_segment)

    result = query_api.query(query=FLUX_QUERY)

    point_count = 0
    for table in result:
        for record in table.records:
            lat = record.values.get("navigation.position_lat")
            lon = record.values.get("navigation.position_lon")
            time = record.get_time()

            if lat is not None and lon is not None:
                track_point = gpxpy.gpx.GPXTrackPoint(
                    latitude=lat,
                    longitude=lon,
                    time=time
                )

                # 1. Speed Over Ground (Signal K m/s maps directly to GPX speed)
                sog = record.values.get("navigation.speedOverGround_value")
                if sog is not None:
                    track_point.speed = float(sog)

                # 2. Course / Bearing (Convert Signal K radians to degrees for GPX course)
                bearing_rad = record.values.get("navigation.course.calcValues.bearingMagnetic_value")
                if bearing_rad is not None:
                    track_point.course = math.degrees(float(bearing_rad)) % 360

                # 3. Apparent Wind Speed (Custom Extension Tag)
                aws_ms = record.values.get("environment.wind.speedApparent_value")
                if aws_ms is not None:
                    # Convert m/s to knots for standard marine analysis
                    aws_knots = float(aws_ms) * 1.94384

                    ext_element = ET.Element("ApparentWindSpeedKnots")
                    ext_element.text = f"{aws_knots:.2f}"
                    track_point.extensions.append(ext_element)

                gpx_segment.points.append(track_point)
                point_count += 1

    client.close()

    with open(output_filename, "w", encoding="utf-8") as f:
        f.write(gpx.to_xml())

    print(f"Exported {point_count} track points with telemetry to {output_filename}")

if __name__ == "__main__":
    generate_gpx_with_telemetry()
