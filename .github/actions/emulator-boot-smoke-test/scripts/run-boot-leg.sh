#!/usr/bin/env bash
set -euo pipefail

# Boots the emulator inside a single container invocation and asserts everything that
# does not depend on locale: the device is reachable, reports the matrix's SDK level,
# the baked AVD was found (a mount over /opt/android/user would silently mask it), and
# the android CLI pre-warm did not regress (no 235 MB re-download).
#
# Usage: run-boot-leg.sh <image> <api_level> <container_name> [-- extra docker run args...]

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$script_dir/lib.sh"

image=$1
api_level=$2
container_name=$3
shift 3

output_log=$(mktemp)

start_container "$container_name" "$image" "$@"

if ! boot_and_wait "$container_name" "$output_log"; then
    echo "ERROR: emulator failed to reach ANDROID_READY on $container_name" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

devices_output=$(docker exec "$container_name" adb devices)
# Deliberately unanchored at the end, matching emulator-lib.sh's own device-state
# check, in case a future adb version appends extra columns after the state.
if ! grep -qE '^emulator-5554[[:space:]]+device' <<<"$devices_output"; then
    echo "ERROR: 'adb devices' does not list emulator-5554 as 'device':" >&2
    echo "$devices_output" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

# System images from API 37 on are named after the full SDK version ("37.0"), while
# ro.build.version.sdk only reports the major ("37").
expected_sdk=${api_level%%.*}
actual_sdk=$(docker exec "$container_name" adb shell getprop ro.build.version.sdk | tr -d '\r\n')
if [[ "$actual_sdk" != "$expected_sdk" ]]; then
    echo "ERROR: ro.build.version.sdk is '$actual_sdk', expected '$expected_sdk'" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

avd_list=$(docker exec "$container_name" avdmanager list avd)
if grep -q "Unknown AVD" <<<"$avd_list" || ! grep -q "android-ci" <<<"$avd_list"; then
    echo "ERROR: AVD 'android-ci' was not found (a volume mounted over /opt/android/user may have masked it):" >&2
    echo "$avd_list" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

# Regression guard: a re-download here means the android CLI pre-warm (build time)
# was skipped or ANDROID_USER_HOME drifted — every downstream CI job would eat 235 MB.
if grep -q "Downloading Android CLI" "$output_log"; then
    echo "ERROR: 'Downloading Android CLI' appeared in container output — pre-warm regression" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

docker exec "$container_name" emulator-tools stop
rm -f "$output_log"
echo "Boot leg OK for $container_name (API $api_level)"
