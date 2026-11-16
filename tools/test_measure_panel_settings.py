# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "measure_panel_settings", Path(__file__).with_name("measure-panel-settings.py"))
measure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure)

KINDS = ("source", "switch", "toggle", "choice", "timer", "numberEdit", "textEdit", "button", "label")


class PanelMeasurementTests(unittest.TestCase):
    def samples(self, percent=9):
        return "\n".join(
            "\n".join([f"{name} 2 parent=8"]
                      + [f"{name} {percent} row:{index}:{kind}=1"
                         for index, kind in enumerate(KINDS, 1)]
                      + [f"{name} 10 finish=8", f"{name} 3 back=8"])
            for name in sorted(measure.EXPECTED)
        )

    def test_exact_drawers_and_exclusive_buckets(self):
        samples = measure.parse_samples(self.samples(), "rows")
        self.assertEqual(len(samples), 23 * 12)
        self.assertEqual(samples[1]["callback_instructions_below"], 2000)

    def test_row_threshold_is_independent_of_existing_grant(self):
        text = self.samples().replace("row:1:source=1", "row:1:source=8")
        measure.parse_samples(text, "rows")
        with self.assertRaisesRegex(RuntimeError, "one native slot"):
            measure.parse_samples(self.samples(10), "rows")

    def test_complete_callbacks_and_lifecycle_threshold(self):
        text = self.samples().replace("chart 9 row:1:source=1\nchart 9 row:2:switch=1",
                                      "chart 74 row:1:source=1,row:2:switch=1")
        measure.parse_samples(text, "callbacks")
        with self.assertRaisesRegex(RuntimeError, "one native slot|callback packing"):
            measure.parse_samples(text, "rows")
        with self.assertRaisesRegex(RuntimeError, "over-budget"):
            measure.parse_samples(text.replace("chart 74 ", "chart 75 "), "callbacks")
        with self.assertRaisesRegex(RuntimeError, "callback packing"):
            measure.parse_samples(text.replace("row:2:switch=1", "row:2:switch=8"), "callbacks")

    def test_rejects_missing_repeated_or_malformed_steps(self):
        text = self.samples()
        for invalid in ("", text.replace("chart 10 finish=8\n", ""),
                        text.replace("row:1:source=1", "row:2:source=1"),
                        text.replace("finish=8", "finish=1"),
                        text.replace("parent=8", "unknown=8"),
                        text.replace("back=8", "back=9"),
                        text.replace("chart 9 ", "chart -1 ")):
            with self.subTest(invalid=invalid[:80]):
                with self.assertRaises(RuntimeError):
                    measure.parse_samples(invalid, "rows")


if __name__ == "__main__":
    unittest.main()
