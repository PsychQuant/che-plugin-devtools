#!/usr/bin/env python3
"""Tests for validate-changelog.py.

Run: python3 plugins/doc-guardian/scripts/test-validate-changelog.py

Black-box: every case invokes the real CLI in a subprocess and asserts on exit
code + stderr text. That is deliberate — this script IS a CLI (CI consumes its
exit codes), so testing the callable surface catches things an import-level test
cannot: unhandled tracebacks, argparse behaviour, and the exact wording CI logs
will show a human at 2am.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "validate-changelog.py"


def run_cli(*args):
    """Invoke the validator. Returns (exit_code, stdout, stderr)."""
    p = subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
    )
    return p.returncode, p.stdout, p.stderr


GOOD_CHANGELOG = """# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-07-31

### Added

- A thing that is new.
"""


class Fixture:
    """A throwaway marketplace containing one plugin, wired for the happy path."""

    def __init__(self, tmp: Path, *, version="1.2.0", mp_version="1.2.0",
                 description=None, mp_description=None):
        # doc-guardian requires each description to lead with the version it
        # documents — the marketplace listing shows description and nothing
        # else, so a description that omits the version leaves consumers unable
        # to tell what changed. Default the fixtures to the compliant shape.
        description = description if description is not None else f"v{version}: Does the thing."
        mp_description = mp_description if mp_description is not None else f"v{mp_version}: Does the thing."
        self.root = tmp
        self.plugin = tmp / "plugins" / "demo"
        (self.plugin / ".claude-plugin").mkdir(parents=True)
        (self.plugin / "CHANGELOG.md").write_text(GOOD_CHANGELOG, encoding="utf-8")
        (self.plugin / ".claude-plugin" / "plugin.json").write_text(
            json.dumps({"name": "demo", "version": version,
                        "description": description}), encoding="utf-8")

        (tmp / ".claude-plugin").mkdir(parents=True)
        self.marketplace_json = tmp / ".claude-plugin" / "marketplace.json"
        self.marketplace_json.write_text(json.dumps({
            "name": "demo-marketplace",
            "plugins": [{"name": "demo", "version": mp_version,
                         "description": mp_description,
                         "source": "./plugins/demo"}],
        }), encoding="utf-8")


class MarketplaceArgTests(unittest.TestCase):
    """#3 — --marketplace accepted a json path only; a directory crashed."""

    def test_directory_is_resolved_to_marketplace_json(self):
        """Passing the marketplace ROOT must work, not crash.

        The usage text itself advertised `<marketplace-json>/.claude-plugin/
        marketplace.json`, i.e. a directory with the suffix appended. The
        implementation only ever accepted the full file path, so following the
        documented form raised IsADirectoryError.
        """
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            code, out, err = run_cli(str(fx.plugin), "--marketplace", str(fx.root))
            self.assertNotIn("Traceback", err, "must not raise an unhandled exception")
            self.assertEqual(code, 0, f"expected clean pass, got {code}\n{err}")
            self.assertEqual(json.loads(out)["marketplace_version"], "1.2.0",
                             "directory form must read the same entry as the file form")

    def test_directory_without_marketplace_json_reports_cleanly(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            empty = Path(td) / "not-a-marketplace"
            empty.mkdir()
            code, _out, err = run_cli(str(fx.plugin), "--marketplace", str(empty))
            self.assertNotIn("Traceback", err)
            self.assertEqual(code, 4, "unusable --marketplace path is a CLI error")
            self.assertIn("marketplace.json", err)

    def test_nonexistent_path_reports_cleanly(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            code, _out, err = run_cli(str(fx.plugin), "--marketplace",
                                      str(Path(td) / "nope.json"))
            self.assertNotIn("Traceback", err)
            self.assertEqual(code, 4)

    def test_file_path_still_works(self):
        """The previously-only-supported form must keep working."""
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            code, out, err = run_cli(str(fx.plugin), "--marketplace",
                                     str(fx.marketplace_json))
            self.assertEqual(code, 0, err)
            self.assertEqual(json.loads(out)["marketplace_version"], "1.2.0")


class ReportHonestyTests(unittest.TestCase):
    """#3 — omitting --marketplace printed '3-way sync OK' for a 2-way check."""

    def test_without_marketplace_does_not_claim_three_way(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            code, out, err = run_cli(str(fx.plugin))
            self.assertEqual(code, 0, err)
            self.assertIsNone(json.loads(out)["marketplace_version"],
                              "no marketplace was read")
            self.assertNotIn("3-way sync OK", err,
                             "claiming a 3-way pass without reading marketplace.json "
                             "is a false green — it is exactly the drift this tool exists to catch")

    def test_without_marketplace_says_what_it_actually_checked(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            _code, _out, err = run_cli(str(fx.plugin))
            self.assertIn("2-way", err, "report must name the check it performed")

    def test_with_marketplace_still_says_three_way(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            _code, _out, err = run_cli(str(fx.plugin), "--marketplace",
                                       str(fx.marketplace_json))
            self.assertIn("3-way sync OK", err)


class RegressionTests(unittest.TestCase):
    """Existing behaviour that must not break — no coverage existed before."""

    def test_missing_changelog_exits_1(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            (fx.plugin / "CHANGELOG.md").unlink()
            code, _out, _err = run_cli(str(fx.plugin))
            self.assertEqual(code, 1)

    def test_version_drift_exits_3(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td), mp_version="1.1.0")   # marketplace behind
            code, _out, err = run_cli(str(fx.plugin), "--marketplace",
                                      str(fx.marketplace_json))
            self.assertEqual(code, 3, err)
            self.assertIn("drift", err)

    def test_plugin_path_not_a_directory_exits_4(self):
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td))
            code, _out, err = run_cli(str(fx.plugin / "CHANGELOG.md"))
            self.assertEqual(code, 4)
            self.assertIn("not a directory", err)

    def test_summary_json_is_always_emitted_on_stdout(self):
        """CI parses stdout; it must stay clean JSON even when the run fails."""
        with tempfile.TemporaryDirectory() as td:
            fx = Fixture(Path(td), mp_version="9.9.9")
            _code, out, _err = run_cli(str(fx.plugin), "--marketplace",
                                       str(fx.marketplace_json))
            json.loads(out)  # raises if stdout got polluted


if __name__ == "__main__":
    unittest.main(verbosity=2)
