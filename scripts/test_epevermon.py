import asyncio
import json
import socket
import struct
import sys
import tempfile
import threading
import unittest
from importlib.util import find_spec
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).parent / "dalymon"))
sys.path.insert(0, str(Path(__file__).parent / "epevermon"))

from epevermon import controller_loop, export, load_config, write_influx
from protocol import Controller, ModbusReader, ProtocolError, poll, rtu_frame, status_fields
from solar_sink import solar_values
from signalk_sink import SignalKSink, _sk_values


class FakeSocket:
    def __init__(self, reply: bytes, fragment: int = 1):
        self.reply = reply
        self.fragment = fragment
        self.sent = b""
        self.timeout = None

    def sendall(self, data):
        self.sent += data

    def settimeout(self, timeout):
        self.timeout = timeout

    def recv(self, size):
        chunk = self.reply[:min(size, self.fragment)]
        self.reply = self.reply[len(chunk):]
        return chunk


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.controller = Controller("MPPT", "epever", "127.0.0.1")

    def test_known_crc_and_fragmented_reply(self):
        self.assertEqual(rtu_frame(bytes.fromhex("010431000001")).hex(), "0104310000013f36")
        connection = FakeSocket(rtu_frame(bytes.fromhex("0104021388")))
        self.assertEqual(ModbusReader(connection, self.controller).read_input(0x3100, 1), [5000])
        self.assertEqual(connection.sent, bytes.fromhex("0104310000013f36"))

    def test_rejects_corrupt_short_wrong_slave_and_wrong_length(self):
        good = rtu_frame(bytes.fromhex("0104021388"))
        for frame in (good[:-1] + bytes([good[-1] ^ 1]), good[:4],
                      rtu_frame(bytes.fromhex("0204021388")), rtu_frame(bytes.fromhex("01040413881388"))):
            with self.subTest(frame=frame.hex()), self.assertRaises(ProtocolError):
                ModbusReader(FakeSocket(frame), self.controller).read_input(0x3100, 1)

    def test_modbus_exception_is_error(self):
        with self.assertRaisesRegex(ProtocolError, "exception 0x02"):
            ModbusReader(FakeSocket(rtu_frame(bytes.fromhex("018402"))), self.controller).read_input(0x3100, 1)

    def test_tcp_mbap_framing_and_transaction_validation(self):
        controller = Controller("MPPT", "epever", "127.0.0.1", transport="tcp")
        reply = bytes.fromhex("0001000000050104021388")
        connection = FakeSocket(reply)
        self.assertEqual(ModbusReader(connection, controller).read_input(0x3100, 1), [5000])
        self.assertEqual(connection.sent.hex(), "000100000006010431000001")
        for frame in (bytes.fromhex("0002000000050104021388"),
                      bytes.fromhex("0001000000ff0104021388"),
                      bytes.fromhex("000100000003018402")):
            with self.subTest(frame=frame.hex()), self.assertRaises(ProtocolError):
                ModbusReader(FakeSocket(frame), controller).read_input(0x3100, 1)

    def test_timeout_propagates_and_whole_reply_has_deadline(self):
        connection = FakeSocket(b"")
        with patch.object(connection, "recv", side_effect=socket.timeout("timed out")):
            with self.assertRaises(TimeoutError):
                ModbusReader(connection, self.controller).read_input(0x3100, 1)
        connection = FakeSocket(rtu_frame(bytes.fromhex("0104021388")))
        with patch("protocol.time.monotonic", side_effect=[0, 0, 6]):
            with self.assertRaises(TimeoutError):
                ModbusReader(connection, self.controller).read_input(0x3100, 1)

    def test_register_ranges_and_controller_validation(self):
        for address, count in ((0, 0), (0, 126), (65535, 2), (-1, 1)):
            with self.assertRaises(ValueError):
                ModbusReader(FakeSocket(b""), self.controller).read_input(address, count)
        for options in ({"slave": 0}, {"slave": 248}, {"port": 0},
                        {"transport": "udp"}, {"timeout": 0}, {"interval": float("nan")},
                        {"id": "bad.id"}, {"interval": True}, {"slave": 1.2}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                Controller(**{"name": "MPPT", "id": "epever", "host": "127.0.0.1", **options})

    def test_real_register_scaling_word_order_and_signed_temperature(self):
        replies = {
            0x3100: [4200, 250, 0x93E0, 4, 1320, 650, 8580, 0],
            0x310C: [1320, 100, 1320, 0],
            0x3110: [65536 - 525, 2875],
            0x3200: [0, 9],
            0x330C: [123, 0],
        }
        with patch("protocol.socket.create_connection"), patch("protocol.time.sleep"), \
                patch.object(ModbusReader, "read_input", side_effect=lambda address, count: replies[address]) as reader:
            data = poll(self.controller)
        self.assertEqual(data["pv_power"], 3000.0)
        self.assertEqual(data["pv_voltage"], 42.0)
        self.assertEqual(data["charge_current"], 6.5)
        self.assertEqual(data["battery_temperature"], -5.25)
        self.assertEqual(data["controller_temperature"], 28.75)
        self.assertEqual(data["yield_today_kwh"], 1.23)
        self.assertEqual(data["charging_state"], "boost")
        self.assertEqual([call.args for call in reader.call_args_list],
                         [(0x3100, 8), (0x310C, 4), (0x3110, 2), (0x3200, 2), (0x330C, 2)])

    def test_failed_poll_never_returns_zero_sample(self):
        with patch("protocol.socket.create_connection", side_effect=TimeoutError):
            with self.assertRaises(TimeoutError):
                poll(self.controller)

    def test_full_poll_over_real_fragmented_tcp_stream(self):
        failures = []
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            server.settimeout(3)

            def gateway():
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(3)
                        for _ in range(5):
                            request = b""
                            while len(request) < 8:
                                chunk = connection.recv(8 - len(request))
                                if not chunk:
                                    raise AssertionError("client disconnected before request")
                                request += chunk
                            self.assertEqual(request, rtu_frame(request[:-2]))
                            slave, function, _, count = struct.unpack(">BBHH", request[:-2])
                            self.assertEqual(function, 4)
                            reply = rtu_frame(bytes([slave, 4, count * 2]) + bytes(count * 2))
                            for byte in reply:
                                connection.sendall(bytes([byte]))
                except (OSError, AssertionError) as error:
                    failures.append(error)

            thread = threading.Thread(target=gateway, daemon=True)
            thread.start()
            controller = Controller("Test", "epever", "127.0.0.1", port=server.getsockname()[1], timeout=3)
            data = poll(controller)
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(data["pv_power"], 0)
        self.assertFalse(data["problem"])

    def test_status_faults_do_not_treat_night_as_failure(self):
        self.assertFalse(status_fields(0, 0x4000)["problem"])
        self.assertEqual(status_fields(0, 5)["charging_state"], "float")
        data = status_fields(0x8111, 0xA013)
        self.assertTrue(data["problem"])
        self.assertIn("Battery overvoltage", data["faults"])
        self.assertIn("Battery overtemperature", data["faults"])
        self.assertIn("PV input overvoltage", data["faults"])
        self.assertIn("Charging MOSFET short circuit", data["faults"])
        self.assertIn("Unmapped", status_fields(0x0200, 0x0020)["faults"])


class ExportTests(unittest.TestCase):
    def test_access_can_be_requested_before_any_samples_exist(self):
        sink = SignalKSink({"enabled": True, "token_file": "/nonexistent/epever-test-token"})
        with patch("signalk_sink.websockets", object()), \
                patch.object(sink, "_ensure_token_sync", return_value=False) as access:
            self.assertFalse(asyncio.run(sink.ensure_access()))
        access.assert_called_once()

    @unittest.skipUnless(find_spec("influxdb_client"), "validated in installed monitor environment")
    def test_influx_measurement_tags_timestamp_and_field_types(self):
        from datetime import datetime, timezone
        from unittest.mock import MagicMock

        writer = MagicMock()
        with patch("influxdb_client.InfluxDBClient") as client:
            client.return_value.__enter__.return_value.write_api.return_value.__enter__.return_value = writer
            write_influx({"url": "http://localhost:8086", "org": "test", "token": "test", "bucket": "Battery"},
                         Controller("MPPT", "epever", "localhost"),
                         datetime(2026, 10, 10, tzinfo=timezone.utc),
                         {"pv_power": 0, "problem": False, "charging_state": "off"})
        values = writer.write.call_args.kwargs
        self.assertEqual(values["bucket"], "Battery")
        point = values["record"].to_line_protocol()
        self.assertIn("solar_status,controller_id=epever,controller_name=MPPT ", point)
        self.assertIn("pv_power=0", point)
        self.assertNotIn("pv_power=0i", point)
        self.assertIn("problem=false", point)
        self.assertIn('charging_state="off"', point)
        self.assertTrue(point.endswith("1791590400000000000"))

    @unittest.skipUnless(find_spec("influxdb_client"), "validated in installed monitor environment")
    def test_influx_failure_does_not_block_signal_k(self):
        from influxdb_client.rest import ApiException

        sink = AsyncMock()
        with patch("epevermon.write_influx", side_effect=ApiException(status=503)), self.assertLogs("epevermon", level="ERROR"):
            asyncio.run(export({"influxdb": {"enabled": True}}, Controller("MPPT", "epever", "localhost"),
                               {"pv_power": 10.0}, sink))
        sink.send.assert_awaited_once()

    def test_read_failure_retries_without_publishing(self):
        class StopLoop(Exception):
            pass

        with patch("epevermon.poll", side_effect=TimeoutError("no response")), \
                patch("epevermon.export", new_callable=AsyncMock) as output, \
                patch("epevermon.asyncio.sleep", new_callable=AsyncMock, side_effect=StopLoop) as sleep, \
                self.assertLogs("epevermon", level="ERROR"):
            with self.assertRaises(StopLoop):
                asyncio.run(controller_loop({}, Controller("Test", "epever", "localhost"), None))
            output.assert_not_awaited()
            sleep.assert_awaited_once_with(5)

    def test_signal_k_solar_units_and_no_battery_overwrite(self):
        data = {
            "pv_voltage": 42.0, "pv_current": 2.5, "pv_power": 105.0,
            "battery_voltage": 13.2, "charge_current": 6.5, "charge_power": 85.8,
            "load_current": 1.0, "controller_temperature": 28.75, "yield_today_kwh": 1.23,
            "charging_state": "boost", "running": True, "faults": "None", "problem": False,
        }
        values = {item["path"]: item["value"] for item in solar_values("epever", data)}
        self.assertAlmostEqual(values["electrical.solar.epever.temperature"], 301.9)
        self.assertEqual(values["electrical.solar.epever.yieldToday"], 4428000)
        self.assertEqual(values["electrical.solar.epever.current"], 6.5)
        self.assertTrue(all(path.startswith("electrical.solar.epever.") for path in values))

    def test_shared_sink_preserves_daly_mapping(self):
        sink = SignalKSink({"token_file": "/nonexistent/epever-test-token"})
        data = {"voltage": 13.2, "current": -2.1, "battery_level": 75, "temperature": 21}
        self.assertEqual(sink.values_for("Hausbatterie", data), _sk_values("hausbatterie", data, False))
        self.assertEqual(sink.description, "Daly BMS monitor (dalymon)")

    def test_jsonl_shape_and_failed_file_does_not_block_signal_k(self):
        sink = AsyncMock()
        controller = Controller("MPPT", "epever", "localhost")
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "samples.jsonl")
            config = {"jsonl": {"enabled": True, "file_path": path}}
            asyncio.run(export(config, controller, {"pv_power": 12.5}, sink))
            record = json.loads(Path(path).read_text())
            self.assertEqual(record["controller_id"], "epever")
            self.assertEqual(record["pv_power"], 12.5)
            self.assertTrue(record["timestamp"].endswith("Z"))
            with patch("epevermon.write_jsonl", side_effect=OSError("disk full")), self.assertLogs("epevermon", level="ERROR"):
                asyncio.run(export(config, controller, {"pv_power": 12.5}, sink))
        self.assertEqual(sink.send.await_count, 2)

    def test_example_configuration_and_duplicate_ids(self):
        path = Path(__file__).parents[1] / "config/epevermon/epevermon.conf.example"
        config, controllers = load_config(str(path))
        self.assertEqual(controllers[0].host, "192.168.42.217")
        self.assertFalse(config["influxdb"]["enabled"])
        text = path.read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.conf"
            path.write_text(text.replace("[jsonl]", '[[controllers]]\nname="duplicate"\nid="epever"\nhost="localhost"\n\n[jsonl]'))
            with self.assertRaisesRegex(ValueError, "unique ids"):
                load_config(str(path))
            path.write_text(text.replace("enabled = false", "enabled = true"))
            with self.assertRaisesRegex(ValueError, "influxdb.token"):
                load_config(str(path))


if __name__ == "__main__":
    unittest.main()
