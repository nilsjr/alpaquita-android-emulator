#!/usr/bin/env bash
set -euo pipefail

# Implements CI assertion #2: boots a maestro-variant image and runs a real Maestro
# flow against it, exercising the same code path the production Jenkins pipeline uses
# (§2.7.4) instead of merely checking that the maestro binary exists.
#
# Usage: maestro-smoke-test.sh <image> <flow_path>

image=$1
flow_path=$2
container_name="maestro-smoke-test"
report_name="maestro-report.junit.xml"

cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$container_name" --device /dev/kvm -e MAESTRO_CLI_NO_ANALYTICS=1 \
    "$image" tail -f /dev/null >/dev/null

if ! docker exec "$container_name" emulator-tools start; then
    echo "ERROR: emulator-tools start failed" >&2
    docker exec "$container_name" cat /tmp/android-emulator/emulator.log 2>&1 || true
    exit 1
fi

if ! docker exec "$container_name" emulator-tools wait-ready; then
    echo "ERROR: emulator never reached ANDROID_READY" >&2
    docker exec "$container_name" cat /tmp/android-emulator/emulator.log 2>&1 || true
    docker exec "$container_name" adb logcat -d 2>&1 || true
    exit 1
fi

docker cp "$flow_path" "$container_name:/tmp/settings-smoke.yaml"

if ! docker exec -e MAESTRO_CLI_NO_ANALYTICS=1 "$container_name" \
    maestro test --format junit --output "/tmp/$report_name" /tmp/settings-smoke.yaml; then
    echo "ERROR: Maestro flow failed" >&2
    docker exec "$container_name" adb logcat -d 2>&1 || true
    exit 1
fi

docker cp "$container_name:/tmp/$report_name" "./$report_name"
echo "Maestro smoke test passed. JUnit report: $report_name"
