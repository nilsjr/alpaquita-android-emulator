#!/usr/bin/env bash
set -euo pipefail

# Boots a second, dedicated container with EMULATOR_LOCALE set and asserts the device
# boots directly into that locale — the §2.7.4 win over the old "boot, setprop,
# stop/start, reboot" dance, verified here without any framework restart.
#
# Usage: run-locale-leg.sh <image> <container_name> <locale>

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$script_dir/lib.sh"

image=$1
container_name=$2
locale=$3

output_log=$(mktemp)

start_container "$container_name" "$image" -e "EMULATOR_LOCALE=$locale"

if ! boot_and_wait "$container_name" "$output_log"; then
    echo "ERROR: emulator failed to reach ANDROID_READY on $container_name" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

actual_locale=$(docker exec "$container_name" adb shell getprop persist.sys.locale | tr -d '\r\n')
if [[ "$actual_locale" != "$locale" ]]; then
    echo "ERROR: persist.sys.locale is '$actual_locale', expected '$locale'" >&2
    dump_diagnostics "$container_name"
    exit 1
fi

docker exec "$container_name" emulator-tools stop
rm -f "$output_log"
echo "Locale leg OK for $container_name ($locale)"
