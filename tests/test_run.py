# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, call, patch


RUNNER = Path(__file__).with_name("run.py")
RUNNER_API = runpy.run_path(str(RUNNER))


class RunnerTests(unittest.TestCase):
    def run_suites(self, *sources):
        with tempfile.TemporaryDirectory(dir=RUNNER.parent.parent) as directory:
            paths = []
            for index, source in enumerate(sources):
                path = Path(directory) / f"test_{index}.lua"
                path.write_text(source, encoding="ascii")
                paths.append(str(path))
            return subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "import runpy, sys; from pathlib import Path; "
                    "run_test = runpy.run_path(sys.argv[1])['run_test']; "
                    "[run_test(Path(path)) for path in sys.argv[2:]]",
                    str(RUNNER),
                    *paths,
                ],
                capture_output=True,
                text=True,
            )

    def test_passing_negative_case_keeps_progress_but_not_error_logs(self):
        result = self.run_suites("""
            local originalPrint = print
            local logs = {}
            print = function(message) logs[#logs + 1] = message end
            print("[AeroGrid] ERROR captured by a test")
            assert(#logs == 1)
            print = originalPrint
            print("[AeroGrid] ERROR expected negative case")
            print("suite passed", 42)
            print("unrelated diagnostic")
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "suite passed\t42\nunrelated diagnostic\n")
        self.assertEqual(result.stderr, "")

    def test_failure_replays_logs_and_preserves_traceback(self):
        result = self.run_suites("""
            print("[AeroGrid] ERROR first", 42, nil, false)
            print("[AeroGrid] ERROR second")
            print("progress before failure")
            assert(false, "deliberate assertion failure")
        """)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "progress before failure\n")
        self.assertIn("Failed Lua suite:", result.stderr)
        self.assertIn("test_0.lua", result.stderr)
        self.assertIn(
            "Captured AeroGrid logs:\n"
            "[AeroGrid] ERROR first\t42\tnil\tfalse\n"
            "[AeroGrid] ERROR second\n",
            result.stderr,
        )
        self.assertIn("Traceback (most recent call last)", result.stderr)
        self.assertIn("deliberate assertion failure", result.stderr)
        self.assertIn("stack traceback:", result.stderr)

    def test_failure_without_logs_still_fails(self):
        result = self.run_suites('error("plain runtime failure")')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed Lua suite:", result.stderr)
        self.assertIn("plain runtime failure", result.stderr)
        self.assertNotIn("Captured AeroGrid logs:", result.stderr)

    def test_logs_and_runtime_are_isolated_between_suites(self):
        result = self.run_suites(
            'leaked = true; print("[AeroGrid] ERROR passing suite only")',
            'assert(leaked == nil); error("second suite failed")',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("second suite failed", result.stderr)
        self.assertNotIn("passing suite only", result.stdout + result.stderr)
        self.assertNotIn("Captured AeroGrid logs:", result.stderr)


class DiscoveryTests(unittest.TestCase):
    def test_discovers_nested_suites_once_in_order_and_excludes_support_modules(self):
        with tempfile.TemporaryDirectory(dir=RUNNER.parent.parent) as directory:
            root = Path(directory)
            suites = [
                "tests/unit/test_contracts.lua",
                "tests/integration/widget/test_widget.lua",
                "tests/integration/test_host.lua",
                "tests/supporting/test_real_suite.lua",
            ]
            excluded = [
                "tests/support/test_helper.lua",
                "tests/integration/support/nested/test_helper.lua",
                "tests/unit/helper.lua",
                "tests/unit/test_python.py",
                "tools/test_tool.lua",
            ]
            for name in suites + excluded:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual(
                RUNNER_API["discover_tests"](root),
                sorted(root / name for name in suites),
            )

    def test_main_runs_every_discovered_suite_once(self):
        suites = [Path("tests/integration/test_host.lua"), Path("tests/unit/test_unit.lua")]
        discover = Mock(return_value=suites)
        run = Mock()
        main = RUNNER_API["main"]
        with patch.dict(main.__globals__, discover_tests=discover, run_test=run):
            main()
        discover.assert_called_once_with()
        self.assertEqual(run.call_args_list, [call(path) for path in suites])


class CompilerCheckTests(unittest.TestCase):
    def run_compiler_check(self, fail_first):
        with tempfile.TemporaryDirectory(dir=RUNNER.parent.parent) as directory:
            root = Path(directory)
            compiler = root / "compiler"
            compiler.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$2" >> compiled.txt\n'
                + ('test "$2" != first.lua\n' if fail_first else "exit 0\n"),
                encoding="ascii",
            )
            compiler.chmod(0o755)
            result = subprocess.run(
                [
                    "make", "--no-print-directory", "-f", str(RUNNER.parent.parent / "Makefile"),
                    "-o", "test", "check", f"LUA_COMPILER={compiler}",
                    "LUA_FILES=first.lua last.lua",
                ],
                cwd=root,
                capture_output=True,
                text=True,
            )
            return result, (root / "compiled.txt").read_text().splitlines()

    def test_earlier_compiler_failure_is_not_masked_by_later_success(self):
        result, compiled = self.run_compiler_check(fail_first=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(compiled, ["first.lua"])

    def test_successful_compiler_checks_every_file(self):
        result, compiled = self.run_compiler_check(fail_first=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(compiled, ["first.lua", "last.lua"])


if __name__ == "__main__":
    unittest.main()
