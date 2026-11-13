"""Check that every Swift localization key has a valid Chinese translation.

Run with python3 -m unittest discover -s tests. Uses macOS's own .strings
parser (plutil), so malformed resources cannot pass a permissive text scan.
"""

import json
from pathlib import Path
import plistlib
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "zh-Hans.lproj" / "Localizable.strings"
KEY = re.compile(r'\bLF?\(\s*("(?:\\.|[^"\\])*")')


class LocalizationTests(unittest.TestCase):
    def keys(self):
        source = (ROOT / "Arowser.swift").read_text(encoding="utf-8")
        keys = {json.loads(match) for match in KEY.findall(source)}
        self.assertTrue(keys, "Arowser.swift has no L()/LF() localization keys")
        return keys

    def translations(self):
        self.assertTrue(TABLE.is_file(), "Missing zh-Hans localization table")
        parsed = subprocess.run(
            ["plutil", "-convert", "xml1", "-o", "-", "--", str(TABLE)],
            capture_output=True,
        )
        self.assertEqual(parsed.returncode, 0, (parsed.stderr + parsed.stdout).decode())
        table = plistlib.loads(parsed.stdout)
        self.assertIsInstance(table, dict)
        return table

    def test_strings_resource_is_parseable(self):
        table = self.translations()
        self.assertTrue(table, "Chinese localization table is empty")
        for key, value in table.items():
            with self.subTest(key=key):
                self.assertIsInstance(value, str)
                self.assertTrue(value, "Translation must not be empty")

    def test_chinese_covers_every_localization_key(self):
        keys = self.keys()
        table = self.translations()
        self.assertEqual(keys - table.keys(), set(), "Missing Chinese translations")


if __name__ == "__main__":
    unittest.main()
