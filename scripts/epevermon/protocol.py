"""Read-only Epever Modbus input registers through a serial TCP gateway.

Register reference: EPsolar Modbus register address list, real-time registers
0x3100/0x310C/0x3110, status 0x3200, and generated energy 0x330C.
32-bit values use low register first; bytes within a register are big endian.
"""

import socket
import struct
import time
from dataclasses import dataclass

Scalar = float | int | bool | str


class ProtocolError(Exception):
    """An invalid frame or a Modbus exception, never a successful sample."""


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    return crc


def rtu_frame(payload: bytes) -> bytes:
    return payload + struct.pack("<H", crc16(payload))


@dataclass(frozen=True)
class Controller:
    name: str
    id: str
    host: str
    port: int = 9999
    slave: int = 1
    timeout: float = 5
    interval: float = 30
    transport: str = "rtu"

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not isinstance(self.host, str) or not self.name or not self.host:
            raise ValueError("controller name and host must not be empty")
        if not isinstance(self.id, str) or not self.id or not self.id.isascii() or not self.id.isalnum():
            raise ValueError("controller id must contain only ASCII letters and digits")
        if type(self.port) is not int or type(self.slave) is not int:
            raise ValueError("port and slave must be integers")
        if not 1 <= self.port <= 65535 or not 1 <= self.slave <= 247:
            raise ValueError("port must be 1..65535 and slave must be 1..247")
        if any(isinstance(value, bool) or not isinstance(value, (int, float))
               for value in (self.timeout, self.interval)):
            raise ValueError("timeout and interval must be numeric")
        if not 0 < self.timeout <= 60 or not 0 < self.interval <= 86400:
            raise ValueError("timeout must be 0..60 seconds and interval 0..86400 seconds (exclusive of zero)")
        if self.transport not in ("rtu", "tcp"):
            raise ValueError("transport must be 'rtu' (serial frames) or 'tcp' (MBAP)")


class ModbusReader:
    """One connection per poll; only function 0x04 is exposed."""

    def __init__(self, connection: socket.socket, controller: Controller) -> None:
        self.connection = connection
        self.controller = controller
        self.transaction = 0

    def _receive(self, size: int, deadline: float) -> bytes:
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out receiving Modbus reply")
            self.connection.settimeout(remaining)
            chunk = self.connection.recv(size - len(data))
            if not chunk:
                raise ProtocolError("gateway disconnected during Modbus reply")
            data.extend(chunk)
        return bytes(data)

    def read_input(self, address: int, count: int) -> list[int]:
        if not 1 <= count <= 125 or not 0 <= address <= 65536 - count:
            raise ValueError("invalid input-register range")
        request = struct.pack(">BBHH", self.controller.slave, 4, address, count)
        deadline = time.monotonic() + self.controller.timeout
        self.connection.settimeout(self.controller.timeout)
        if self.controller.transport == "rtu":
            self.connection.sendall(rtu_frame(request))
            header = self._receive(3, deadline)
            if header[1] == 0x84:
                frame = header + self._receive(2, deadline)
            elif header[1] == 4:
                if header[2] != count * 2:
                    raise ProtocolError(f"unexpected byte count {header[2]} for {count} registers")
                frame = header + self._receive(header[2] + 2, deadline)
            else:
                raise ProtocolError(f"unexpected function 0x{header[1]:02x}")
            if crc16(frame[:-2]) != struct.unpack("<H", frame[-2:])[0]:
                raise ProtocolError("Modbus CRC mismatch")
            if frame[0] != self.controller.slave:
                raise ProtocolError(f"unexpected slave address {frame[0]}")
            pdu = frame[1:-2]
        else:
            self.transaction = (self.transaction + 1) & 0xFFFF
            self.connection.sendall(struct.pack(">HHH", self.transaction, 0, len(request)) + request)
            header = self._receive(7, deadline)
            transaction, protocol, length, slave = struct.unpack(">HHHB", header)
            if transaction != self.transaction or protocol != 0 or slave != self.controller.slave:
                raise ProtocolError("Modbus TCP transaction, protocol or slave mismatch")
            if not 3 <= length <= 253:
                raise ProtocolError(f"invalid Modbus TCP length {length}")
            pdu = self._receive(length - 1, deadline)
        if pdu[0] == 0x84:
            if len(pdu) != 2:
                raise ProtocolError("invalid Modbus exception length")
            raise ProtocolError(f"Modbus exception 0x{pdu[1]:02x} reading 0x{address:04x}")
        if pdu[0] != 4 or len(pdu) != count * 2 + 2 or pdu[1] != count * 2:
            raise ProtocolError("invalid Modbus input-register response")
        return list(struct.unpack(f">{count}H", pdu[2:]))


def _u32(low: int, high: int) -> int:
    return low | (high << 16)


def _temperature(value: int) -> float:
    return (value if value < 0x8000 else value - 0x10000) / 100


def status_fields(battery: int, charger: int) -> dict[str, Scalar]:
    faults: list[str] = []
    voltage = battery & 0xF
    temperature = (battery >> 4) & 0xF
    if voltage:
        faults.append({1: "Battery overvoltage", 2: "Battery undervoltage",
                       3: "Battery low-voltage disconnect", 4: "Battery voltage fault"}.get(
                           voltage, f"Unknown battery voltage status {voltage}"))
    if temperature:
        faults.append({1: "Battery overtemperature", 2: "Battery low temperature"}.get(
            temperature, f"Unknown battery temperature status {temperature}"))
    for bit, text in ((8, "Battery internal resistance abnormal"), (15, "Battery rated voltage mismatch")):
        if battery & (1 << bit):
            faults.append(text)
    for bit, text in (
        (1, "Charging equipment fault"), (4, "PV input short circuit"),
        (7, "Load MOSFET short circuit"), (8, "Load short circuit"),
        (9, "Load overcurrent"), (10, "PV input overcurrent"),
        (11, "Anti-reverse MOSFET short circuit"),
        (12, "Charging or anti-reverse MOSFET short circuit"),
        (13, "Charging MOSFET short circuit"),
    ):
        if charger & (1 << bit):
            faults.append(text)
    input_state = (charger >> 14) & 3
    if input_state >= 2:
        faults.append(("PV input overvoltage", "PV input voltage error")[input_state - 2])
    unknown_battery = battery & ~0x81FF
    unknown_charger = charger & ~0xFF9F
    if unknown_battery:
        faults.append(f"Unmapped battery status bits 0x{unknown_battery:04x}")
    if unknown_charger:
        faults.append(f"Unmapped charging status bits 0x{unknown_charger:04x}")
    return {
        "battery_status": battery,
        "charger_status": charger,
        "charging_state": ("off", "float", "boost", "equalize")[(charger >> 2) & 3],
        "running": bool(charger & 1),
        "pv_input_state": ("normal", "no input", "overvoltage", "error")[input_state],
        "problem": bool(faults),
        "fault_count": len(faults),
        "faults": "; ".join(faults) or "None",
    }


def poll(controller: Controller) -> dict[str, Scalar]:
    with socket.create_connection((controller.host, controller.port), timeout=controller.timeout) as connection:
        reader = ModbusReader(connection, controller)
        # Separate documented blocks avoid reading reserved registers on older firmware.
        registers: dict[int, int] = {}
        for address, count in ((0x3100, 8), (0x310C, 4), (0x3110, 2), (0x3200, 2), (0x330C, 2)):
            registers.update(enumerate(reader.read_input(address, count), start=address))
            time.sleep(0.01)
    return {
        "pv_voltage": registers[0x3100] / 100,
        "pv_current": registers[0x3101] / 100,
        "pv_power": _u32(registers[0x3102], registers[0x3103]) / 100,
        "battery_voltage": registers[0x3104] / 100,
        "charge_current": registers[0x3105] / 100,
        "charge_power": _u32(registers[0x3106], registers[0x3107]) / 100,
        "load_voltage": registers[0x310C] / 100,
        "load_current": registers[0x310D] / 100,
        "load_power": _u32(registers[0x310E], registers[0x310F]) / 100,
        "battery_temperature": _temperature(registers[0x3110]),
        "controller_temperature": _temperature(registers[0x3111]),
        "yield_today_kwh": _u32(registers[0x330C], registers[0x330D]) / 100,
        **status_fields(registers[0x3200], registers[0x3201]),
    }
