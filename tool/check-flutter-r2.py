"""Summarize only test outcomes from the Flutter machine stream."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("events", type=Path)
parser.add_argument("report", type=Path)
parser.add_argument("--strict-stage2", action="store_true")
args = parser.parse_args()

tests = {}
suites = {}
outcomes = []
errors = {}
recovery = []
done = []
for line in args.events.read_text(encoding="utf-8-sig").splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if not isinstance(event, dict):
        continue
    kind = event.get("type")
    if kind == "suite":
        suites[event["suite"]["id"]] = event["suite"].get("path") or ""
    elif kind == "testStart":
        tests[event["test"]["id"]] = event["test"]
    elif kind == "testDone" and not event.get("hidden"):
        outcomes.append(event)
    elif kind == "print" and event.get("message", "").startswith("Stage 2B recovery call="):
        recovery.append(event["message"])
    elif kind == "error":
        errors[event.get("testID")] = event.get("error", "")
    elif kind == "done":
        done.append(event.get("success") is True)

passed = 0
failed = 0
failed_tests = []
skipped = []
allowed_skips = []
for event in outcomes:
    test = tests[event["testID"]]
    name = test["name"]
    suite = Path(suites.get(test["suiteID"], "")).name
    if event.get("skipped"):
        skipped.append(name)
        if suite == "stage2b_live_test.dart":
            allowed_skips.append(name)
    elif event["result"] == "success":
        passed += 1
    else:
        failed += 1
        detail = {"suite": suite, "test": name}
        if suite == "update_windows_transaction_test.dart":
            # This fixture only uses a disposable dummy executable and paths.
            detail["error"] = errors.get(event["testID"], "")[:1000]
        failed_tests.append(detail)

report = dict(passed=passed, failed=failed, failed_tests=failed_tests, skipped=skipped, recovery=recovery)
args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report))
if done != [True] or failed:
    raise SystemExit("Flutter machine stream did not show a complete successful suite")
if args.strict_stage2:
    if passed != 7 or skipped or len(recovery) != 2:
        raise SystemExit("Strict Stage 2B requires seven passes and two recovery measurements")
elif passed < 501 or len(skipped) != 7 or skipped != allowed_skips:
    raise SystemExit("Unexpected Flutter test count or skipped tests")
