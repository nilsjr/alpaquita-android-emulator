#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for the emulator boot smoke test legs (run-boot-leg.sh, run-locale-leg.sh).
# Sourced, not executed directly.

# Starts a container in appliance mode (build-agent CMD, so it needs an explicit
# foreground command to stay alive) and registers a cleanup trap for it.
start_container() {
    local container_name=$1 image=$2
    shift 2
    docker run -d --name "$container_name" --device /dev/kvm "$@" "$image" tail -f /dev/null >/dev/null
    # shellcheck disable=SC2064 # expand container_name now, not when the trap fires
    trap "docker rm -f '$container_name' >/dev/null 2>&1 || true" EXIT
}

# Runs emulator-tools start + wait-ready, tee-ing combined output to output_log so
# callers can grep it afterwards (e.g. for the "Downloading Android CLI" regression).
# Uses explicit early returns instead of relying on set -e across pipelines, since
# this function is called from an `if`/`!` context where errexit is suspended.
boot_and_wait() {
    local container_name=$1 output_log=$2

    if ! docker exec "$container_name" emulator-tools start 2>&1 | tee -a "$output_log"; then
        return 1
    fi

    if ! docker exec "$container_name" emulator-tools wait-ready 2>&1 | tee -a "$output_log"; then
        return 1
    fi
}

# Dumps logcat + the emulator's own log for post-mortem debugging on failure.
dump_diagnostics() {
    local container_name=$1
    echo "::group::Diagnostics for $container_name"
    echo "--- docker logs $container_name ---"
    docker logs "$container_name" 2>&1 || true
    echo "--- /tmp/android-emulator/emulator.log ---"
    docker exec "$container_name" cat /tmp/android-emulator/emulator.log 2>&1 || true
    echo "--- adb logcat -d ---"
    docker exec "$container_name" adb logcat -d 2>&1 || true
    echo "::endgroup::"
}
