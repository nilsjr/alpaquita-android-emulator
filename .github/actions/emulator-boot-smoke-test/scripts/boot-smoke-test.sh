#!/usr/bin/env bash
set -euo pipefail

# Orchestrates CONTRACT.md's CI assertion #1: the root leg (release gate), the
# alternate-UID leg (future-proofing only, not a release gate — §6.2), and the
# locale leg (the §2.7.4 win), each in its own container so a failure on one leg
# cannot poison the next.
#
# Each leg runs as a separate script invocation (a fresh bash process) rather than a
# sourced function, so that calling it inside `if ...; then` does not suspend
# set -euo pipefail for the leg's own internal logic — a well-known bash quirk where
# errexit is not honored for commands used as an `if`/`while` condition.
#
# Usage: boot-smoke-test.sh <image> <api_level>

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image=$1
api_level=$2
locale="de-DE"
overall_result=0

echo "::group::Boot leg (root)"
if "$script_dir/run-boot-leg.sh" "$image" "$api_level" "emulator-boot-root"; then
    echo "Root leg passed."
else
    echo "Root leg FAILED — this is a release gate." >&2
    overall_result=1
fi
echo "::endgroup::"

echo "::group::Boot leg (alternate UID, future-proofing only)"
if "$script_dir/run-boot-leg.sh" "$image" "$api_level" "emulator-boot-altuid" --user 12345:0 -e HOME=/tmp; then
    echo "Alternate-UID leg passed."
else
    echo "::warning::Alternate-UID leg failed — future-proofing only (§6.2), not a release gate."
fi
echo "::endgroup::"

echo "::group::Locale leg"
if "$script_dir/run-locale-leg.sh" "$image" "emulator-boot-locale" "$locale"; then
    echo "Locale leg passed."
else
    echo "Locale leg FAILED — this is a release gate." >&2
    overall_result=1
fi
echo "::endgroup::"

exit "$overall_result"
