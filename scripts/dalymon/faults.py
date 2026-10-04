"""Daly D2 alarm-bit names verified against the D2 BLE status frame."""

D2_ALARM_NAMES = {
    16: "Charging MOS over-temperature warning",
    17: "Discharging MOS over-temperature warning",
    18: "Charging MOS temperature sensor failure",
    19: "Discharging MOS temperature sensor failure",
    20: "Charging MOS adhesion failure",
    21: "Discharging MOS adhesion failure",
    22: "Charging MOS circuit fault",
    23: "Discharging MOS circuit fault",
    24: "AFE acquisition chip failure",
    25: "Single-cell acquisition offline",
    26: "Single temperature sensor failure",
    27: "EEPROM storage failure",
    28: "RTC clock failure",
    29: "Precharge failed",
    30: "Vehicle communication failed",
    31: "Internal network communication module failure",
    32: "Warning: charging current too high",
    33: "Critical: charging current too high",
    34: "Warning: discharging current too low",
    35: "Critical: discharging current too low",
    36: "Warning: SOC too high",
    37: "Critical: SOC too high",
    38: "Warning: SOC too low",
    39: "Critical: SOC too low",
    40: "Warning: voltage difference too high",
    41: "Critical: voltage difference too high",
    42: "Warning: temperature difference too high",
    43: "Critical: temperature difference too high",
    48: "Warning: cell voltage too high",
    49: "Critical: cell voltage too high",
    50: "Warning: cell voltage too low",
    51: "Critical: cell voltage too low",
    52: "Warning: total voltage too high",
    53: "Critical: total voltage too high",
    54: "Warning: total voltage too low",
    55: "Critical: total voltage too low",
    56: "Warning: charging temperature too high",
    57: "Critical: charging temperature too high",
    58: "Warning: charging temperature too low",
    59: "Critical: charging temperature too low",
    60: "Warning: discharging temperature too high",
    61: "Critical: discharging temperature too high",
    62: "Warning: discharging temperature too low",
    63: "Critical: discharging temperature too low",
}


def decode_daly_d2_faults(problem_code: int | None) -> list[str]:
    """Decode a 64-bit Daly D2 status alarm mask into active fault names."""
    try:
        mask = int(problem_code or 0) & ((1 << 64) - 1)
    except (TypeError, ValueError, OverflowError):
        return []

    faults = []
    for bit in range(64):
        if mask & (1 << bit):
            faults.append(
                D2_ALARM_NAMES.get(bit, f"Reserved or unmapped Daly alarm bit {bit}")
            )
    return faults


def format_daly_d2_problem_code(problem_code: int | None) -> str:
    """Format the raw unsigned alarm mask without losing 64-bit precision."""
    try:
        mask = int(problem_code or 0) & ((1 << 64) - 1)
    except (TypeError, ValueError, OverflowError):
        mask = 0
    return f"0x{mask:016X}"