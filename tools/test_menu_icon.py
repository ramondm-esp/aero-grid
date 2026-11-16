# SPDX-License-Identifier: GPL-2.0-only
"""Native header geometry regression tests, independent of simulator availability."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from tool_test_support import load_tool

ROOT = Path(__file__).resolve().parents[1]

icons = load_tool("menu_icons", "generate-menu-icon.py")
capture = load_tool("menu_capture", "capture-editor.py")


class MenuIconTests(unittest.TestCase):
    def test_selected_straight_grid_design(self):
        svg = ET.parse(ROOT / "src/WIDGETS/AeroGrid/assets/aerogrid.svg").getroot()
        ns = {"svg": "http://www.w3.org/2000/svg"}
        self.assertIsNone(svg.find("svg:path", ns))
        grid = svg.find("svg:g", ns)
        self.assertEqual(grid.get("fill"), "#DCEAF0")
        self.assertEqual(grid.get("clip-path"), "url(#grid-inset)")
        tiles = grid.findall("svg:rect", ns)
        self.assertEqual(len(tiles), 9)
        self.assertEqual({float(tile.get("x")) for tile in tiles}, {6, 17.5, 29})
        self.assertEqual({float(tile.get("y")) for tile in tiles}, {6, 17.5, 29})
        self.assertTrue(all(tile.get("transform") is None for tile in tiles))
        plane = svg.find("svg:image", ns)
        self.assertEqual(plane.get("x"), "4.5")
        self.assertEqual(plane.get("y"), "1")
        self.assertIsNone(plane.get("transform"))

    def test_transparent_artwork_assets_at_every_display_size(self):
        for size in (36, 45, 62):
            rows = icons.read_png(ROOT / "src/WIDGETS/AeroGrid/assets" / icons.asset_name(size))
            self.assertEqual(len(rows), size)
            self.assertTrue(all(len(row) == size for row in rows))
            self.assertEqual(rows[0][0][3], 0)
            self.assertEqual(rows[0][-1][3], 0)
            self.assertGreater(sum(pixel[3] > 0 for row in rows for pixel in row), 0)
            opaque_colors = {
                pixel[:3]
                for row in rows
                for pixel in row
                if pixel[3] == 255
            }
            self.assertIn((220, 234, 240), opaque_colors)
            self.assertTrue(any(min(pixel[:3]) >= 250 for pixel in opaque_colors))

    def test_capture_comparison_rejects_hitbox_only_parity(self):
        black = bytes(480 * 3)
        rows = [black for _ in range(272)]
        for y in range(45):
            rows[y] = bytes([255] * (45 * 3)) + black[45 * 3:]
        report = capture.verify_menu_icon_pair(rows, rows)
        self.assertEqual(report["bounds"], [0, 0, 45, 45])
        smaller = list(rows)
        smaller[0] = black
        with self.assertRaisesRegex(RuntimeError, "silhouettes differ"):
            capture.verify_menu_icon_pair(rows, smaller)
        narrower = list(rows)
        narrower[0] = bytes([255] * (44 * 3)) + black[44 * 3:]
        report = capture.verify_menu_icon_pair(rows, narrower)
        self.assertEqual(report["matching_rows"], 44)
        self.assertEqual(report["max_edge_difference"], 1)
        narrower[0] = bytes([255] * (43 * 3)) + black[43 * 3:]
        with self.assertRaisesRegex(RuntimeError, "silhouettes differ"):
            capture.verify_menu_icon_pair(rows, narrower)
        wider = list(rows)
        wider[0] = bytes([255] * (46 * 3)) + black[46 * 3:]
        with self.assertRaisesRegex(RuntimeError, "silhouettes differ"):
            capture.verify_menu_icon_pair(rows, wider)
        hole = list(rows)
        hole[0] = rows[0][:30] + bytes(3) + rows[0][33:]
        with self.assertRaisesRegex(RuntimeError, "silhouettes differ"):
            capture.verify_menu_icon_pair(rows, hole)


if __name__ == "__main__":
    unittest.main()
