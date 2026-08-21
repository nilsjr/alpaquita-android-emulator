#!/usr/bin/env bash
# shellcheck disable=SC2154
# File-wide: emulator_pid_file, emulator_serial and is_pid_alive come from emulator-lib.sh,
# sourced below from its installed, absolute path, which static analysis cannot follow.
#
# Installed as /usr/local/bin/emulator-healthcheck. Default mode (no args) is what the
# Dockerfile's HEALTHCHECK uses; --strict is for k8s exec probes that must only report healthy
# once a real emulator has booted.
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/emulator-lib.sh

strict_mode=false
if [ "${1:-}" = "--strict" ]; then
    strict_mode=true
fi

process_running=false
if [ -f "${emulator_pid_file}" ] && is_pid_alive "$(cat "${emulator_pid_file}")"; then
    process_running=true
fi

if [ "${process_running}" = "false" ]; then
    if [ "${strict_mode}" = "true" ]; then
        echo "Unhealthy: --strict requires a booted emulator, but no emulator process is running." >&2
        exit 1
    fi
    # No emulator process means this container is only being used as a plain build agent,
    # which is a healthy state in itself.
    exit 0
fi

boot_completed=$(adb -s "${emulator_serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)

if [ "${boot_completed}" = "1" ]; then
    exit 0
fi

echo "Unhealthy: emulator process is running but sys.boot_completed is '${boot_completed:-unset}'." >&2
exit 1
