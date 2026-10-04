import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "dalymon"))

from faults import decode_daly_d2_faults, format_daly_d2_problem_code


class DalyFaultTests(unittest.TestCase):
    def test_zero_mask_has_no_faults(self):
        self.assertEqual(decode_daly_d2_faults(0), [])
        self.assertEqual(format_daly_d2_problem_code(0), "0x0000000000000000")

    def test_decodes_alarm_bits_in_mask_order(self):
        mask = (1 << 16) | (1 << 24) | (1 << 43) | (1 << 63)
        self.assertEqual(
            decode_daly_d2_faults(mask),
            [
                "Charging MOS over-temperature warning",
                "AFE acquisition chip failure",
                "Critical: temperature difference too high",
                "Critical: discharging temperature too low",
            ],
        )
        self.assertEqual(format_daly_d2_problem_code(mask), "0x8000080001010000")

    def test_reserved_bits_are_not_silently_dropped(self):
        self.assertEqual(
            decode_daly_d2_faults((1 << 5) | (1 << 46)),
            [
                "Reserved or unmapped Daly alarm bit 5",
                "Reserved or unmapped Daly alarm bit 46",
            ],
        )

    def test_invalid_mask_input_is_empty(self):
        self.assertEqual(decode_daly_d2_faults(None), [])
        self.assertEqual(decode_daly_d2_faults("invalid"), [])


if __name__ == "__main__":
    unittest.main()