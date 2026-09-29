#!/bin/zsh
# DriveScope build helper. Pins Xcode 27.2 beta via DEVELOPER_DIR (xcode-select is left untouched).
#
#   scripts/xc.sh build            Build the app for the simulator → prints the .app path
#   scripts/xc.sh build-device     Compile for a generic iOS device (no signing) — catches device-only errors
#   scripts/xc.sh test             Package tests on macOS (fast, `swift test`)
#   scripts/xc.sh test-ios         App tests (UI tests) on the iOS simulator
#   scripts/xc.sh test-ui          UI tests only
#   scripts/xc.sh run [args...]    Build, install and launch on the simulator (extra args go to the app)
#   scripts/xc.sh route <gpx|name> Play a location route on the booted simulator (see scripts/routes/)
#   scripts/xc.sh sim              Print the simulator UDID used
#   scripts/xc.sh <anything else>  Run it with the pinned toolchain (e.g. `scripts/xc.sh xcrun simctl list`)
set -euo pipefail

export DEVELOPER_DIR="${DRIVESCOPE_DEVELOPER_DIR:-/Applications/Xcode-beta 27.2.app/Contents/Developer}"
ROOT="${0:A:h:h}"
PROJECT="$ROOT/DriveScope.xcodeproj"
SIM_NAME="${DRIVESCOPE_SIM:-iPhone 18 Pro}"
SIM_OS="${DRIVESCOPE_SIM_OS:-27.2}"
DERIVED="$ROOT/.build/DerivedData"
BUNDLE_ID="com.miquottty.DriveScope"

sim_udid() {
  xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name, os_ver = sys.argv[1], sys.argv[2].replace(".", "-")
runtimes = json.load(sys.stdin)["devices"]
def version(runtime):
    return [int(x) for x in runtime.rsplit("iOS-", 1)[1].split("-")]
# "latest" (CI): the newest iOS runtime that has this device.
candidates = sorted((r for r in runtimes if "iOS-" in r), key=version, reverse=True) if os_ver == "latest" \
    else [r for r in runtimes if r.endswith("iOS-" + os_ver)]
for runtime in candidates:
    for d in runtimes[runtime]:
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
sys.exit("simulator not found: %s (iOS %s)" % (name, sys.argv[2]))' "$SIM_NAME" "$SIM_OS"
}

boot() {
  local udid=$1
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

summarize() {
  # Prints pass/fail counts and failures from a result bundle.
  xcrun xcresulttool get test-results summary --path "$1" --compact | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
print("RESULT: %s  total=%s passed=%s failed=%s skipped=%s" % (d["result"], d["totalTestCount"], d["passedTests"], d["failedTests"], d["skippedTests"]))
for f in d.get("testFailures", []):
    print("FAIL %s: %s" % (f.get("testName"), f.get("failureText")))
sys.exit(0 if d["result"] == "Passed" else 1)'
}

xctest() {
  local udid=$(sim_udid); boot "$udid"
  local bundle="$ROOT/.build/TestResults/$(date +%Y%m%d-%H%M%S).xcresult"
  mkdir -p "$ROOT/.build/TestResults"
  xcb -scheme DriveScope -destination "platform=iOS Simulator,id=$udid" -resultBundlePath "$bundle" test "$@" 2>&1 \
    | grep -vE "xcodebuild\[[0-9]+:[0-9]+\] \[MT\]" || true
  summarize "$bundle"
}

xcb() {
  # -quiet keeps logs short; errors still print. Signing is off for simulator builds.
  xcodebuild -project "$PROJECT" -derivedDataPath "$DERIVED" -quiet \
    CODE_SIGNING_ALLOWED=NO "$@"
}

cmd="${1:-build}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
  sim)
    sim_udid ;;
  build)
    udid=$(sim_udid)
    xcb -scheme DriveScope -configuration Debug -destination "platform=iOS Simulator,id=$udid" build "$@"
    echo "$DERIVED/Build/Products/Debug-iphonesimulator/DriveScope.app" ;;
  build-device)
    # Compile-only check for the iphoneos SDK (device-only code paths); no signing.
    xcb -scheme DriveScope -configuration Debug -destination "generic/platform=iOS" build "$@" && echo "device build OK" ;;
  test)
    (cd "$ROOT/Packages/DriveKit" && swift test --quiet "$@") ;;
  test-ios)
    xctest "$@" ;;
  test-ui)
    xctest -only-testing:DriveScopeUITests "$@" ;;
  run)
    udid=$(sim_udid); boot "$udid"
    xcb -scheme DriveScope -configuration Debug -destination "platform=iOS Simulator,id=$udid" build
    app="$DERIVED/Build/Products/Debug-iphonesimulator/DriveScope.app"
    xcrun simctl install "$udid" "$app"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" ;;
  route)
    udid=$(sim_udid); boot "$udid"
    "$ROOT/scripts/sim-route.sh" "$udid" "$@" ;;
  *)
    "$cmd" "$@" ;;
esac
