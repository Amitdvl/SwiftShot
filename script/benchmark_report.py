#!/usr/bin/env python3
"""Compare explicit SwiftShot metadata exports and controlled XCTest logs.

No screen contents, account names, titles, OCR strings, or file paths are emitted.
Renderer microbenchmarks are kept separate from real workflow measurements.
"""
import argparse
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

PREFIX = "SWIFTSHOT_BENCHMARK "
MAX_INPUT_BYTES = 64 * 1024 * 1024


def percentile95(values):
    values = sorted(values)
    return values[math.ceil(len(values) * 0.95) - 1] if values else None


def valid_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def context_key(context):
    return json.dumps(context, sort_keys=True, separators=(",", ":"))


def load(paths):
    micro = []
    runs = {}
    expected = set()
    dropped = 0
    active = 0
    environments = []
    for path in dict.fromkeys(Path(path).resolve() for path in paths):
        if path.stat().st_size > MAX_INPUT_BYTES:
            raise ValueError("Input exceeds the 64 MiB metadata/log limit")
        with path.open(encoding="utf-8") as stream:
            first = stream.read(1)
            stream.seek(0)
            if first == "{" or first.isspace() and path.suffix == ".json":
                report = json.load(stream)
                if report.get("schemaVersion") != 1 or not isinstance(report.get("runs"), list):
                    raise ValueError("Unsupported workflow report schema")
                for run in report["runs"]:
                    if run.get("outcome") not in {"success", "failed", "canceled"}:
                        raise ValueError("Workflow report has an invalid outcome")
                    runs[run["id"]] = run
                for summary in report.get("summaries", []):
                    expected.add((summary["workflow"], context_key(summary["context"]), summary["span"]))
                dropped = max(dropped, report.get("droppedRuns", 0) + report.get("droppedActiveRuns", 0))
                active = max(active, report.get("activeRuns", 0))
                environments.append(report.get("environment", {}))
            else:
                count = 0
                for line in stream:
                    position = line.find(PREFIX)
                    if position < 0:
                        continue
                    sample = json.loads(line[position + len(PREFIX):])
                    if sample.get("schemaVersion") != 1 or sample.get("kind") != "renderer-microbenchmark":
                        raise ValueError("Unsupported benchmark sample schema")
                    if not valid_number(sample.get("renderMilliseconds")):
                        raise ValueError("Invalid renderer duration")
                    micro.append(sample)
                    count += 1
                if not count:
                    raise ValueError("Input contains no workflow report or benchmark samples")
    return {"micro": micro, "runs": list(runs.values()), "expected": expected,
            "dropped": dropped, "active": active, "environments": environments}


def label_context(raw):
    c = json.loads(raw)
    def size(key):
        value = c.get(key)
        return f"{value['width']}×{value['height']}" if value else "unknown"
    return " / ".join([c.get("launch", "unspecified"), c.get("desktop", "unspecified"),
                       f"displays={c.get('displayCount', 'unknown')}", f"{size('inputPixels')}→{size('outputPixels')}",
                       c.get("interaction", "unspecified"), c.get("content", "unspecified")])


def groups(dataset):
    result = defaultdict(lambda: {"latencies": [], "runs": [], "failed": 0, "canceled": 0, "missing": 0})
    for sample in dataset["micro"]:
        key = ("Renderer microbenchmark", sample["scenario"], sample["lifecycle"])
        result[key]["latencies"].append(sample["renderMilliseconds"])
        result[key]["runs"].append(sample)
    workflow_runs = defaultdict(list)
    for run in dataset["runs"]:
        if run["workflow"] == "idleObservation":
            key = ("Process observation", "idle duration", label_context(context_key(run["context"])))
            if run["outcome"] == "success":
                if not valid_number(run.get("durationMilliseconds")):
                    raise ValueError("Invalid observation duration")
                result[key]["latencies"].append(run["durationMilliseconds"])
                result[key]["runs"].append(run)
            else:
                result[key][run["outcome"]] += 1
        key = (run["workflow"], context_key(run["context"]))
        workflow_runs[key].append(run)
        for measurement in run.get("measurements", []):
            dataset["expected"].add((*key, measurement["span"]))
    for workflow, context, span in dataset["expected"]:
        key = ("Software workflow", f"{workflow}: {span}", label_context(context))
        group = result[key]
        for run in workflow_runs[(workflow, context)]:
            if run["outcome"] != "success":
                group[run["outcome"]] += 1
                continue
            measurement = next((m for m in run.get("measurements", []) if m["span"] == span), None)
            if not measurement or not valid_number(measurement.get("milliseconds")):
                group["missing"] += 1
                continue
            group["latencies"].append(measurement["milliseconds"])
            group["runs"].append(run)
    return result


def fmt(value):
    return "—" if value is None else f"{value:.3f}"


def escape(value):
    return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def stats(group):
    values = group["latencies"]
    return len(values), statistics.median(values) if values else None, percentile95(values)


def median_field(records, key):
    values = [r[key] for r in records if valid_number(r.get(key))]
    return statistics.median(values) if values else None


def render(baseline, current):
    old, new = groups(baseline), groups(current)
    lines = ["# SwiftShot Benchmark Comparison", "",
             "Renderer measurements are microbenchmarks, not shortcut, clipboard, paste, OCR, or history latency. "
             "Software readiness is not proof of physical frame presentation. Missing evidence is not a passing gate.", "",
             "Legacy shortcutToSelector spans start at the accepted capture method, after global-shortcut queue handoffs. "
             "They are a lower bound on full shortcut response; inspect the matching captureLatencyTrace "
             "shortcutReceived → final selector receiptDelivered interval before evaluating that target.", "",
             "Median uses the middle value (mean of the middle two for even n); p95 is nearest-rank. "
             "Failed/canceled runs remain counted but are excluded from successful-latency statistics. "
             "Fewer than 30 samples per condition is insufficient acceptance evidence.", "",
             "| Kind / Workflow / Condition | Baseline n | Baseline median ms | Baseline p95 ms | Current n | Current median ms | Current p95 ms | Median change |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for key in sorted(set(old) | set(new)):
        a, b = old[key], new[key]
        na, ma, pa = stats(a)
        nb, mb, pb = stats(b)
        change = "—" if ma is None or mb is None or ma == 0 else f"{(mb / ma - 1) * 100:+.1f}%"
        lines.append(f"| {escape(' / '.join(key))} | {na} | {fmt(ma)} | {fmt(pa)} | {nb} | {fmt(mb)} | {fmt(pb)} | {change} |")
    lines += ["", "## Completeness and Resources", "",
              "CPU is process-wide user+system time, not isolated workflow CPU. RSS is sampled at each run's boundaries; "
              "peak RSS is the process-lifetime high-water mark, not a per-run peak. Resource figures cover the full run, not individual spans. "
              "Actions/corrections are absent when not observed and for renderer tests. CPU percent may exceed 100% with multiple cores.", "",
              "| Build / Workflow / Condition | Failed | Canceled | Missing span | Median CPU ms | Median CPU % | Median end RSS MiB | Median RSS delta MiB | Max lifetime RSS MiB | Median actions | Median corrections |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for build, dataset in [("Baseline", old), ("Current", new)]:
        for key, group in sorted(dataset.items()):
            runs = group["runs"]
            rss = median_field(runs, "residentEndBytes")
            deltas = [(r["residentEndBytes"] - r["residentStartBytes"]) / 1048576 for r in runs
                      if valid_number(r.get("residentEndBytes")) and valid_number(r.get("residentStartBytes"))]
            peaks = [r["peakResidentBytes"] / 1048576 for r in runs if valid_number(r.get("peakResidentBytes"))]
            cpu_percent = [r["cpuMilliseconds"] / r.get("durationMilliseconds", r.get("renderMilliseconds")) * 100 for r in runs
                           if valid_number(r.get("cpuMilliseconds")) and valid_number(r.get("durationMilliseconds", r.get("renderMilliseconds")))
                           and r.get("durationMilliseconds", r.get("renderMilliseconds")) > 0]
            lines.append(f"| {escape(build + ' / ' + ' / '.join(key))} | {group['failed']} | {group['canceled']} | {group['missing']} | "
                         f"{fmt(median_field(runs, 'cpuMilliseconds'))} | {fmt(statistics.median(cpu_percent) if cpu_percent else None)} | "
                         f"{fmt(rss / 1048576 if rss is not None else None)} | {fmt(statistics.median(deltas) if deltas else None)} | "
                         f"{fmt(max(peaks) if peaks else None)} | {fmt(median_field(runs, 'actions'))} | {fmt(median_field(runs, 'corrections'))} |")
    for name, data in [("Baseline", baseline), ("Current", current)]:
        lines += ["", f"{name}: {data['dropped']} dropped records/active runs; {data['active']} active runs at export."]
        if data["dropped"] or data["active"]:
            lines.append("This export is incomplete; recollect before making an acceptance claim.")
    lines += ["", "No target is automatically waived or declared achieved by this comparison.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", nargs="+", required=True, metavar="REPORT_OR_LOG")
    parser.add_argument("--current", nargs="+", required=True, metavar="REPORT_OR_LOG")
    parser.add_argument("--output", type=Path, help="Explicit Markdown output; otherwise write to stdout")
    args = parser.parse_args()
    try:
        report = render(load(args.baseline), load(args.current))
        if args.output:
            args.output.write_text(report, encoding="utf-8")
        else:
            print(report, end="")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Cannot produce a valid comparison: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
