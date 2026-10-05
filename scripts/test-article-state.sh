#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/yomy-state-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp -R "$root/Tests/StateHarness/." "$work/"
mkdir -p "$work/Sources/YomiState"
# Compile the actual app files, not hand-maintained test doubles or reimplementations.
cp "$root"/Yomi/Models/*.swift "$work/Sources/YomiState/"
cp "$root"/Yomi/Services/*.swift "$work/Sources/YomiState/"
# Hosted lifecycle tests render the actual SwiftUI views after SwiftData deletion.
cp -R "$root/Yomi/Views" "$work/Sources/YomiState/Views"
cp "$root/Shared/WidgetDataStore.swift" "$work/Sources/YomiState/"
if [ -n "${YOMY_BASELINE_REF:-}" ]; then
    git -C "$root" show "$YOMY_BASELINE_REF:Yomi/Services/FeedService.swift" > "$work/Sources/YomiState/FeedService.swift"
fi
cd "$work"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x["name"].startswith("iPhone")))')"
status=0
xcodebuild -scheme YomiState -destination "platform=iOS Simulator,id=$device" \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$work/StateTests.xcresult" \
    test CODE_SIGNING_ALLOWED=NO "$@" || status=$?
if [ "$status" -ne 0 ]; then
    # Keep crash/timeout details in CI logs before the temporary harness is removed.
    xcrun xcresulttool get test-results summary --path "$work/StateTests.xcresult" || true
    xcrun xcresulttool get object --legacy --format json --path "$work/StateTests.xcresult" || true
fi
exit "$status"
