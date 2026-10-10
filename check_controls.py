"""Check protocol fixtures and reject bad inputs without touching USB."""
import json
from pathlib import Path
import subprocess
import unittest

TOOL = str(Path(__file__).resolve().parent / "enviouscooler")


def run(*args):
    return subprocess.run([TOOL, *args, "--dry-run"], capture_output=True, text=True)


class ProtocolChecks(unittest.TestCase):
    def simulate(self, temperatures):
        result = subprocess.run([TOOL, "simulate", ",".join(map(str, temperatures))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [row["rpm"] for row in json.loads(result.stdout)["decisions"]]

    def test_smooth_rise_is_bounded_and_reaches_max(self):
        speeds = self.simulate([40] * 5 + [85] * 100)
        self.assertEqual(speeds[:5], [800] * 5)
        self.assertTrue(all(0 <= b - a <= 200 for a, b in zip(speeds, speeds[1:])))
        self.assertGreaterEqual(speeds[-1], 3100)  # 100 RPM hysteresis band
        self.assertTrue(all(800 <= rpm <= 3200 and rpm % 50 == 0 for rpm in speeds))

    def test_emergency_bypasses_smoothing(self):
        self.assertEqual(self.simulate([40, 95])[-1], 3200)

    def test_cooldown_waits_then_descends_gradually(self):
        speeds = self.simulate([95] + [40] * 150)
        self.assertEqual(speeds[:11], [3200] * 11)
        self.assertTrue(all(0 <= a - b <= 100 for a, b in zip(speeds, speeds[1:])))
        self.assertLessEqual(speeds[-1], 900)

    def test_brief_heat_spike_does_not_rev_fan(self):
        speeds = self.simulate([40] * 10 + [75] + [40] * 10)
        self.assertEqual(max(speeds), 800)

    def test_malformed_temperature_is_rejected(self):
        for text in ["40,nan", "40,garbage", "40,", "-1", "126"]:
            result = subprocess.run([TOOL, "simulate", text], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)

    def test_known_windows_fan_packet(self):
        result = run("fan", "2700")
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = bytes.fromhex(json.loads(result.stdout)["packet_hex"])
        # Independent fixture from the published Windows FanControl implementation.
        expected = bytearray(90)
        expected[:12] = bytes.fromhex("00 02 00 00 00 03 0d 01 01 05 36 00")
        expected[88] = 0x3D
        self.assertEqual(packet, expected)

    def test_off_packet(self):
        packet = bytes.fromhex(json.loads(run("fan", "off").stdout)["packet_hex"])
        self.assertEqual(packet[:12], bytes.fromhex("00 02 00 00 00 03 0d 10 00 06 00 00"))
        self.assertEqual(packet[88], 0x18)

    def test_static_red_packet(self):
        packet = bytes.fromhex(json.loads(run("rgb", "ff0000").stdout)["packet_hex"])
        self.assertEqual(packet[5:17], bytes.fromhex("09 0f 02 01 00 01 00 00 01 ff 00 00"))
        self.assertEqual(packet[88], 0xFA)

    def test_rejects_invalid_inputs(self):
        for args in [("fan", "0"), ("fan", "499"), ("fan", "500"), ("fan", "550"),
                     ("fan", "750"), ("fan", "3250"),
                     ("fan", "1525"), ("fan", "NaN"), ("brightness", "-1"),
                     ("brightness", "101"), ("rgb", "ffffff00"),
                     ("rgb", "zzzzzz"), ("firmware", "flash"),
                     ("test-rpm", "700"),
                     ("fan", "1500", "extra")]:
            with self.subTest(args=args):
                result = run(*args)
                self.assertEqual(result.returncode, 1)
                self.assertIn("error", json.loads(result.stderr))


if __name__ == "__main__":
    unittest.main()
