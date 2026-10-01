#!/usr/bin/env bash
# Shared functions for emulator-tools, emulator-entrypoint and emulator-healthcheck.
# Always sourced from its installed, absolute path (/usr/local/bin/emulator-lib.sh) — never
# executed directly.
set -euo pipefail

# Fixed by the contract: the emulator is always launched with `-port 5554`, which pins its
# ADB transport id to this serial.
emulator_serial="emulator-5554"

emulator_state_dir="/tmp/android-emulator"
emulator_log_file="${emulator_state_dir}/emulator.log"

# These three are read only by the scripts that source this file (emulator-tools,
# emulator-entrypoint.sh, emulator-healthcheck), never by a function defined here — hence the
# per-line disables below.
# shellcheck disable=SC2034
emulator_pid_file="${emulator_state_dir}/emulator.pid"
# shellcheck disable=SC2034
emulator_xvfb_pid_file="${emulator_state_dir}/xvfb.pid"
# shellcheck disable=SC2034
emulator_socat_pid_file="${emulator_state_dir}/socat.pids"

# Only the two variables consumed directly inside this file's own functions need a default
# here; every other runtime variable is defaulted by whichever script actually reads it.
: "${EMULATOR_BOOT_TIMEOUT:=600}"
: "${EMULATOR_REQUIRE_KVM:=true}"

# /tmp is world-writable, so this works under any UID without a GID-0 dance.
ensure_state_dir() {
    mkdir -p "${emulator_state_dir}"
}

is_pid_alive() {
    local pid="${1:-}"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

# Writes one JSON line to stdout. This is readable log output, not a parsed protocol: the
# production pipeline that inherited this format never actually consumes it.
write_log() {
    local log_type="$1" value="$2"
    printf '{"type":"%s","value":"%s"}\n' "${log_type}" "${value}"
}

update_state() {
    write_log "state-update" "$1"
}

dump_emulator_log_tail() {
    echo "---- last 50 lines of ${emulator_log_file} ----" >&2
    if [ -f "${emulator_log_file}" ]; then
        tail -n 50 "${emulator_log_file}" >&2
    else
        echo "(no emulator log found at ${emulator_log_file})" >&2
    fi
}

is_adb_device_present() {
    adb devices | grep -qE "^${emulator_serial}[[:space:]]+device"
}

is_boot_completed() {
    local prop
    prop=$(adb -s "${emulator_serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [ "${prop}" = "1" ]
}

# -change-locale applies the locale only after the first sys.boot_completed=1 and then restarts
# the framework (at least once, even when the locale was already persisted), while
# sys.boot_completed stays 1 throughout. A restarted system_server (start_count >= 2) whose
# user 0 is unlocked again is the earliest point the device is usable in the new locale.
is_locale_applied() {
    local state
    # One device-side snapshot instead of three round trips; the expansions run on the device.
    # shellcheck disable=SC2016
    state=$(adb -s "${emulator_serial}" shell \
        'echo "$(getprop persist.sys.locale) $(getprop sys.system_server.start_count) $(am get-started-user-state 0 2>/dev/null)"' \
        2>/dev/null | tr -d '\r')
    local locale start_count user_state
    read -r locale start_count user_state <<<"${state}"
    [ "${locale}" = "${EMULATOR_LOCALE}" ] &&
        [ "${start_count:-0}" -ge 2 ] &&
        [ "${user_state}" = "RUNNING_UNLOCKED" ]
}

# Polls `predicate` (a function name) until it succeeds or `deadline` (epoch seconds) passes.
wait_for_condition() {
    local deadline="$1" interval="$2" predicate="$3"
    while ! "${predicate}"; do
        [ "$(date +%s)" -lt "${deadline}" ] || return 1
        sleep "${interval}"
    done
}

# The old repo's equivalent loop was `while [ -n "$(adb wait-for-device > /dev/null)" ]`: the
# command substitution's stdout is discarded, so the condition was always the empty string and
# the loop body never ran (defect #5). This polls real predicates against a real deadline and
# fails loudly — non-zero exit plus the tail of the emulator log — on timeout.
wait_for_boot() {
    local deadline=$(($(date +%s) + EMULATOR_BOOT_TIMEOUT))

    update_state "ANDROID_BOOTING"

    if ! wait_for_condition "${deadline}" 1 is_adb_device_present; then
        echo "Error: ${emulator_serial} never reached adb state 'device' within ${EMULATOR_BOOT_TIMEOUT}s." >&2
        dump_emulator_log_tail
        return 1
    fi

    if ! wait_for_condition "${deadline}" 2 is_boot_completed; then
        echo "Error: ${emulator_serial} never reported sys.boot_completed=1 within ${EMULATOR_BOOT_TIMEOUT}s." >&2
        dump_emulator_log_tail
        return 1
    fi

    [ -n "${EMULATOR_LOCALE:-}" ] || return 0
    if ! wait_for_condition "${deadline}" 1 is_locale_applied; then
        echo "Error: ${emulator_serial} did not come back up in locale '${EMULATOR_LOCALE}' within ${EMULATOR_BOOT_TIMEOUT}s." >&2
        dump_emulator_log_tail
        return 1
    fi
}

disable_animations() {
    adb -s "${emulator_serial}" shell settings put global window_animation_scale 0.0
    adb -s "${emulator_serial}" shell settings put global transition_animation_scale 0.0
    adb -s "${emulator_serial}" shell settings put global animator_duration_scale 0.0
}

enable_hidden_api_policy() {
    adb -s "${emulator_serial}" shell settings put global hidden_api_policy_pre_p_apps 1
    adb -s "${emulator_serial}" shell settings put global hidden_api_policy_p_apps 1
    adb -s "${emulator_serial}" shell settings put global hidden_api_policy 1
}

kvm_preflight() {
    local accel_output
    if accel_output=$(emulator -accel-check 2>&1); then
        return 0
    fi

    if [ "${EMULATOR_REQUIRE_KVM}" = "false" ]; then
        echo "Warning: KVM acceleration check failed; continuing because EMULATOR_REQUIRE_KVM=false." >&2
        echo "${accel_output}" >&2
        return 0
    fi

    {
        echo "Error: KVM acceleration is unavailable (emulator -accel-check failed):"
        echo "${accel_output}"
        echo "Run the container with '--device /dev/kvm' (or 'privileged: true' in Kubernetes) and"
        echo "grant access to /dev/kvm, or set EMULATOR_REQUIRE_KVM=false to run unaccelerated" \
            "(not recommended)."
    } >&2
    return 1
}
