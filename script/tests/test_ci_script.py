"""Exercise the real CI shell with fake tools; never launch Xcode or XCTest."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CI_SCRIPT = Path(__file__).resolve().parents[1] / "ci_test.sh"

FAKE_TOOL = r'''#!/bin/bash
tool="${0##*/}"
printf '%s %s\n' "$tool" "$*" >> "$CI_TOOL_TRACE"
case "$tool" in
  uname)
    if [[ "$1" == -s ]]; then printf '%s\n' "${CI_FAKE_SYSTEM:-Darwin}"
    else echo arm64; fi ;;
  sw_vers) echo 'ProductVersion: 26.0' ;;
  git) exit "${CI_FAKE_DIFF_STATUS:-0}" ;;
  xcodegen)
    if [[ "$1" == --version ]]; then echo 'Version: 2.46.0'
    else exit "${CI_FAKE_GENERATE_STATUS:-0}"; fi ;;
  xcodebuild)
    if [[ "$1" == -version ]]; then echo 'Xcode 26.6'; echo 'Build version 17A123'
    elif [[ "$*" == *build-for-testing* ]]; then exit "${CI_FAKE_BUILD_STATUS:-0}"
    else exit "${CI_FAKE_XCTEST_STATUS:-0}"; fi ;;
  python3)
    if [[ "$1" == --version ]]; then echo 'Python 3.14.0'
    else exit "${CI_FAKE_PYTHON_STATUS:-0}"; fi ;;
  *) exit 99 ;;
esac
'''


class CIScriptTests(unittest.TestCase):
    def run_ci(self, *, inject_nounset=False, **overrides):
        with tempfile.TemporaryDirectory(prefix="SwiftShotCIWrapper-") as temporary:
            root = Path(temporary)
            script_dir = root / "script"
            script_dir.mkdir()
            script = script_dir / "ci_test.sh"
            source = CI_SCRIPT.read_text()
            if inject_nounset:
                # Fault injection before the first command, while preserving the
                # real EXIT handler and Apple's Bash conditional-function behavior.
                source = source.replace("local status=0", 'local status="$CI_INTENTIONALLY_UNSET"', 1)
            script.write_text(source)
            tools = root / "fake-tools"
            tools.mkdir()
            for name in ("uname", "sw_vers", "git", "xcodegen", "xcodebuild", "python3"):
                tool = tools / name
                tool.write_text(FAKE_TOOL)
                tool.chmod(0o755)
            trace = root / "tool-trace.txt"
            environment = os.environ.copy()
            environment.pop("CI_INTENTIONALLY_UNSET", None)
            environment.update(overrides)
            environment.update(PATH=str(tools) + os.pathsep + environment.get("PATH", "/usr/bin:/bin"),
                               CI_TOOL_TRACE=str(trace))
            result = subprocess.run(["/bin/bash", str(script)], cwd=root, env=environment,
                                    capture_output=True, text=True, errors="replace", timeout=20)
            runs = list((root / "build" / "ci").glob("run.*"))
            self.assertEqual(len(runs), 1, result.stdout + result.stderr)
            statuses = {path.name: path.read_text().strip() for path in runs[0].glob("*.txt")}
            return result, statuses, trace.read_text() if trace.exists() else ""

    def assert_status(self, result, statuses, expected):
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(statuses.get("exit-status.txt"), str(expected))

    def test_success_runs_build_and_tests_and_reports_zero(self):
        result, statuses, trace = self.run_ci()
        self.assert_status(result, statuses, 0)
        self.assertIn("Running preflight", result.stdout)
        self.assertIn("build-for-testing", trace)
        self.assertIn("test-without-building", trace)
        self.assertEqual(statuses.get("xcode-tests.exit-status.txt"), "0")

    def test_preflight_failure_stops_before_generation(self):
        result, statuses, trace = self.run_ci(CI_FAKE_SYSTEM="Linux")
        self.assert_status(result, statuses, 1)
        self.assertEqual(statuses.get("preflight.exit-status.txt"), "1")
        self.assertNotIn("xcodegen generate", trace)

    def test_generation_failure_preserves_command_status(self):
        result, statuses, trace = self.run_ci(CI_FAKE_GENERATE_STATUS="23")
        self.assert_status(result, statuses, 23)
        self.assertNotIn("build-for-testing", trace)

    def test_build_failure_skips_tests_and_preserves_status(self):
        result, statuses, trace = self.run_ci(CI_FAKE_BUILD_STATUS="37")
        self.assert_status(result, statuses, 37)
        self.assertEqual(statuses.get("xcode-build.exit-status.txt"), "37")
        self.assertNotIn("test-without-building", trace)
        self.assertIn("tests-not-run.txt", statuses)

    def test_test_failure_preserves_status(self):
        result, statuses, _ = self.run_ci(CI_FAKE_XCTEST_STATUS="42")
        self.assert_status(result, statuses, 42)
        self.assertEqual(statuses.get("xcode-tests.exit-status.txt"), "42")

    def test_first_failure_is_not_hidden_by_later_success_or_failure(self):
        result, statuses, trace = self.run_ci(CI_FAKE_PYTHON_STATUS="19", CI_FAKE_XCTEST_STATUS="42")
        self.assert_status(result, statuses, 19)
        self.assertIn("test-without-building", trace)
        self.assertEqual(statuses.get("xcode-tests.exit-status.txt"), "42")

    def test_internal_nounset_never_reports_success(self):
        result, statuses, trace = self.run_ci(inject_nounset=True)
        self.assertIn("unbound variable", result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(statuses.get("exit-status.txt"), str(result.returncode))
        self.assertNotIn("build-for-testing", trace)


if __name__ == "__main__":
    unittest.main()
