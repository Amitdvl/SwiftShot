import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("benchmark_report", Path(__file__).resolve().parents[1] / "benchmark_report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class BenchmarkReportTests(unittest.TestCase):
    def test_report_discloses_shortcut_handoff_lower_bound(self):
        data = {"micro": [], "runs": [], "expected": set(), "dropped": 0, "active": 0, "environments": []}
        rendered = report.render(data, data)
        self.assertIn("lower bound on full shortcut response", rendered)
        self.assertIn("shortcutReceived → final selector receiptDelivered", rendered)

    def test_percentiles_have_independent_hand_checked_expectations(self):
        self.assertEqual(report.percentile95(list(range(1, 101))), 95)
        self.assertEqual(report.percentile95([40, 10, 30, 20]), 40)
        self.assertIsNone(report.percentile95([]))

    def test_log_reader_extracts_only_valid_marker_metadata(self):
        sample = {"schemaVersion": 1, "kind": "renderer-microbenchmark", "scenario": "ordinary-edited-4k",
                  "lifecycle": "renderer-reuse", "renderMilliseconds": 12.5}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "benchmark.log"
            path.write_text("ignored compiler path and log noise\n" + report.PREFIX + json.dumps(sample) + "\n")
            loaded = report.load([path, path])
        self.assertEqual(loaded["micro"], [sample])
        self.assertEqual(loaded["runs"], [])

    def test_failed_canceled_and_missing_samples_cannot_disappear(self):
        context = {"launch": "resident", "desktop": "idle", "displayCount": 1}
        runs = [{"id": str(index), "workflow": "regionToPaste", "context": context, "outcome": outcome,
                 "measurements": ([{"span": "copyToClipboard", "milliseconds": latency}] if latency is not None else [])}
                for index, (outcome, latency) in enumerate([("success", 10), ("success", 30), ("success", None), ("failed", 1000), ("canceled", 2000)])]
        data = {"micro": [], "runs": runs, "expected": {("regionToPaste", report.context_key(context), "copyToClipboard")}}
        grouped = next(iter(report.groups(data).values()))
        self.assertEqual(report.stats(grouped), (2, 20, 30))
        self.assertEqual(grouped["failed"], 1)
        self.assertEqual(grouped["canceled"], 1)
        self.assertEqual(grouped["missing"], 1)

    def test_cumulative_exports_deduplicate_run_ids(self):
        payload = {"schemaVersion": 1, "runs": [{"id": "same-run", "outcome": "success"}], "summaries": [],
                   "droppedRuns": 1, "activeRuns": 2}
        with tempfile.TemporaryDirectory() as folder:
            first, second = Path(folder) / "first.json", Path(folder) / "second.json"
            first.write_text(json.dumps(payload))
            second.write_text(json.dumps(payload))
            loaded = report.load([first, second])
        self.assertEqual(len(loaded["runs"]), 1)
        self.assertEqual(loaded["dropped"], 1)
        self.assertEqual(loaded["active"], 2)

    def test_no_measurements_is_an_error_not_an_empty_successful_report(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "empty.log"
            path.write_text("Test host failed before emitting samples\n")
            with self.assertRaises(ValueError):
                report.load([path])

    def test_idle_observation_retains_process_resource_evidence(self):
        run = {"id": "idle", "workflow": "idleObservation", "context": {}, "outcome": "success",
               "durationMilliseconds": 60_000, "cpuMilliseconds": 12, "measurements": []}
        data = {"micro": [], "runs": [run], "expected": set()}
        grouped = next(iter(report.groups(data).values()))
        self.assertEqual(grouped["runs"], [run])
        self.assertEqual(grouped["latencies"], [60_000])


if __name__ == "__main__":
    unittest.main()
