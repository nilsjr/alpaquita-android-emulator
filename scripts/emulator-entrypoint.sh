#!/usr/bin/env bash
# shellcheck disable=SC2154
# File-wide: emulator_pid_file and is_pid_alive come from emulator-lib.sh, sourced below from
# its installed, absolute path, which static analysis cannot follow.
#
# Appliance-mode entrypoint: runs as PID 1 when the container is started with
# `--entrypoint emulator-entrypoint` (or a pod `command:`), as opposed to the default
# build-agent mode (`CMD ["/bin/bash"]`) where nothing here runs at all.
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/emulator-lib.sh

# Only ever invoked indirectly, via the trap below.
# shellcheck disable=SC2329
on_terminate() {
    emulator-tools stop || true
    exit 0
}
trap on_terminate SIGTERM SIGINT

emulator-tools start
emulator-tools wait-ready

emulator_pid=$(cat "${emulator_pid_file}")

# A plain, long `sleep` would delay signal handling until it returns. Backgrounding a short
# sleep and waiting on it lets bash — running as PID 1 here — interrupt the wait and run the
# trap as soon as SIGTERM/SIGINT arrives, instead of only between polls.
while is_pid_alive "${emulator_pid}"; do
    sleep 3 &
    wait "$!"
done

echo "Error: the emulator process (pid ${emulator_pid}) exited unexpectedly." >&2
exit 1
