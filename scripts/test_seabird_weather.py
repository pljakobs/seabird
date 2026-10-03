import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("weather", Path(__file__).with_name("seabird-weather.py"))
weather = importlib.util.module_from_spec(spec)
spec.loader.exec_module(weather)


class WeatherTests(unittest.TestCase):
    def setUp(self):
        self.cache = {"products": {"wind": {
            "run": "2026-10-03T00:00:00Z",
            "grid": {"bbox": [8, 53, 10, 55], "width": 1, "height": 1},
            "frames": [
                {"valid": "2026-10-03T03:00:00Z", "values": {"u_ms": [0], "v_ms": [-10]}},
                {"valid": "2026-10-03T09:00:00Z", "values": {"u_ms": [0], "v_ms": [-20]}},
            ],
        }}}

    def test_interpolation_and_wind_from(self):
        result = weather.point_forecast(self.cache, 9, 54, weather.utc("2026-10-03T06:00:00Z"))
        wind = result["products"]["wind"]
        self.assertEqual(wind["v_ms"], -15)
        self.assertEqual(wind["direction_deg"], 0)
        self.assertEqual(wind["speed_kn"], 29.2)

    def test_no_extrapolation(self):
        for when in ("2026-10-03T02:59:59Z", "2026-10-03T09:00:01Z"):
            self.assertIsNone(weather.point_forecast(self.cache, 9, 54, weather.utc(when))["products"]["wind"])

    def test_outside_area_and_nodata(self):
        when = weather.utc("2026-10-03T03:00:00Z")
        self.assertIsNone(weather.point_forecast(self.cache, 20, 54, when)["products"]["wind"])
        self.cache["products"]["wind"]["frames"][0]["values"]["u_ms"] = [None]
        self.assertNotIn("speed_kn", weather.point_forecast(self.cache, 9, 54, when)["products"]["wind"])

    def test_direction_wrap_and_current_to(self):
        product = self.cache["products"]["wind"]
        self.cache["products"]["currents"] = product
        self.assertEqual(weather.point_forecast(self.cache, 9, 54, weather.utc("2026-10-03T03:00:00Z"))["products"]["currents"]["direction_deg"], 180)
        product["frames"][0]["values"] = {"direction_deg": [350]}
        product["frames"][1]["values"] = {"direction_deg": [10]}
        self.assertEqual(weather.interpolate(product, 9, 54, weather.utc("2026-10-03T06:00:00Z"))["direction_deg"], 0)

    def test_route_time_and_intermediate_samples(self):
        points = [{"lon": 9, "lat": 54, "name": "Start"}, {"lon": 9, "lat": 54.2, "name": "End"}]
        result = weather.route_forecast(self.cache, points, weather.utc("2026-10-03T03:00:00Z"), 6)
        self.assertAlmostEqual(result["distance_nm"], 12, delta=0.1)
        self.assertEqual(len(result["samples"]), 4)
        elapsed = (weather.utc(result["arrival"]) - weather.utc(result["departure"])).total_seconds() / 3600
        self.assertAlmostEqual(elapsed, 2, delta=0.01)
        for bad in (0, -1, float("nan"), 100):
            with self.assertRaises(ValueError):
                weather.route_forecast(self.cache, points, weather.utc("2026-10-03T03:00:00Z"), bad)

    def test_gpx_route_and_geojson(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "route.gpx"
            path.write_text('<gpx xmlns="http://www.topografix.com/GPX/1/1"><rte><rtept lat="54" lon="9"><name>A</name></rtept><rtept lat="54.2" lon="9"/></rte></gpx>')
            self.assertEqual(len(weather.route_points(path)), 2)
        result = weather.overlay(self.cache, weather.utc("2026-10-03T03:00:00Z"), "wind")
        self.assertEqual(result["features"][0]["geometry"]["coordinates"], [9, 54])

    def test_requires_timezone(self):
        with self.assertRaises(ValueError):
            weather.utc("2026-10-03T03:00:00")
        self.assertEqual(weather.stamp(weather.utc("2026-10-03T05:00:00+02:00")), "2026-10-03T03:00:00Z")


if __name__ == "__main__":
    unittest.main()