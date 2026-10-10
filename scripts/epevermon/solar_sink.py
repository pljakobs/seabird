"""Solar-specific mapping using the Daly monitor's Signal K authentication."""

from signalk_sink import SignalKSink


def solar_values(controller_id: str, data: dict) -> list[dict]:
    base = f"electrical.solar.{controller_id}"
    fields = {
        "panelVoltage": "pv_voltage",
        "panelCurrent": "pv_current",
        "panelPower": "pv_power",
        "voltage": "battery_voltage",
        "current": "charge_current",
        "power": "charge_power",
        "loadCurrent": "load_current",
    }
    values = [{"path": f"{base}.{path}", "value": data[field]} for path, field in fields.items()]
    values.extend([
        {"path": f"{base}.temperature", "value": data["controller_temperature"] + 273.15},
        {"path": f"{base}.yieldToday", "value": data["yield_today_kwh"] * 3_600_000},
        {"path": f"{base}.chargingMode", "value": {
            "off": "unknown", "float": "float", "boost": "bulk", "equalize": "equalize",
        }[data["charging_state"]]},
        {"path": f"{base}.controllerMode", "value": "MPPT" if data["running"] else "idle"},
        {"path": f"{base}.faults", "value": data["faults"]},
        {"path": f"{base}.problem", "value": data["problem"]},
    ])
    return values


class SolarSink(SignalKSink):
    def values_for(self, name: str, data: dict) -> list[dict]:
        return solar_values(name, data)
