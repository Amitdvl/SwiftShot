#!/usr/bin/env bash
# Deterministic XCTest only: no installation, live capture, TCC, or UI driving.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/build/ci"
RUN_DIR="$(mktemp -d "$ROOT_DIR/build/ci/run.XXXXXX")"
DERIVED_DATA="$RUN_DIR/derived-data.noindex"
FIRST_FAILURE=0
RUN_COMPLETED=0
export PYTHONDONTWRITEBYTECODE=1
# Do not inherit a local benchmark smoke override into the full test suite.
unset SWIFTSHOT_BENCHMARK_SAMPLES TEST_RUNNER_SWIFTSHOT_BENCHMARK_SAMPLES

echo "CI evidence: $RUN_DIR"
finish() {
  local status=$?
  trap - EXIT
  # Apple Bash 3.2 can report zero here after a nounset failure inside a
  # conditionally invoked function. Only the explicit final path may succeed.
  if [[ "$status" -eq 0 && "$RUN_COMPLETED" -ne 1 ]]; then
    status="$FIRST_FAILURE"
    if [[ "$status" -eq 0 ]]; then status=1; fi
  fi
  printf '%s\n' "$status" > "$RUN_DIR/exit-status.txt"
  echo "CI exit status: $status; full logs and result bundles: $RUN_DIR"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_step() {
  local name="$1"
  shift
  local status=0
  echo "Running ${name}..."
  if "$@" > "$RUN_DIR/$name.log" 2>&1; then
    echo "PASS $name"
  else
    status=$?
    echo "FAIL $name (exit $status)" >&2
    tail -80 "$RUN_DIR/$name.log" >&2
    if [[ "$FIRST_FAILURE" -eq 0 ]]; then FIRST_FAILURE="$status"; fi
  fi
  printf '%s\n' "$status" > "$RUN_DIR/$name.exit-status.txt"
  return "$status"
}

preflight() {
  [[ "$(uname -s)" == Darwin ]] || { echo "macOS is required." >&2; return 1; }
  command -v xcodebuild || return "$?"
  command -v xcodegen || return "$?"
  command -v python3 || return "$?"
  sw_vers || return "$?"
  uname -m || return "$?"
  git rev-parse HEAD || return "$?"
  xcodebuild -version || return "$?"
  xcodegen --version || return "$?"
  python3 --version || return "$?"
  [[ "$(xcodebuild -version | head -1)" == "Xcode 26.6" ]] || {
    echo "Select Xcode 26.6 to match CI (DEVELOPER_DIR may be used)." >&2; return 1;
  }
  [[ "$(xcodegen --version)" == "Version: 2.46.0" ]] || {
    echo "XcodeGen 2.46.0 is required to match CI." >&2; return 1;
  }
}

check_diff() {
  git diff --check || return "$?"
  git diff --cached --check || return "$?"
  # In CI, the checkout is clean: inspect the actual commit/PR merge diff too.
  if git rev-parse --verify HEAD^ >/dev/null 2>&1; then
    git diff --check HEAD^ HEAD
  else
    git show --format= --check HEAD
  fi
}

run_step preflight preflight || exit "$FIRST_FAILURE"
run_step diff-check check_diff || :
run_step shell-syntax bash -n script/ci_test.sh || :
run_step benchmark-report-tests python3 -m unittest discover -s script/tests -p 'test_benchmark_report.py' -v || :
run_step ci-wrapper-tests python3 -m unittest discover -s script/tests -p 'test_ci_script.py' -v || :
run_step project-generation xcodegen generate || exit "$FIRST_FAILURE"

XCODE_ARGS=(
  -project SwiftShot.xcodeproj -scheme SwiftShot -configuration Debug
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  -only-testing:SwiftShotTests
  SWIFT_OPTIMIZATION_LEVEL=-O ENABLE_HARDENED_RUNTIME=NO
  MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES
)

# A fresh derived-data path plus clean prevents stale build/test reuse. Ad-hoc
# signing permits XCTest injection; production Release settings stay untouched.
if run_step xcode-build xcodebuild "${XCODE_ARGS[@]}" \
    -resultBundlePath "$RUN_DIR/build.xcresult" clean build-for-testing; then
  run_step xcode-tests xcodebuild "${XCODE_ARGS[@]}" \
    -resultBundlePath "$RUN_DIR/tests.xcresult" test-without-building || :
else
  echo "Tests not run: clean build-for-testing failed." > "$RUN_DIR/tests-not-run.txt"
fi

# Generation must not introduce whitespace errors, either.
run_step final-diff-check check_diff || :
RUN_COMPLETED=1
exit "$FIRST_FAILURE"
