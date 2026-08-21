#!/usr/bin/env bash
set -euo pipefail

api_level=$1
img_type=$2
architecture=$3
expected_emulator_version=$4
ram_mb=$5
cores=$6
data_partition_size=$7
lcd_width=$8
lcd_height=$9
lcd_density=${10}

avd_name=android-ci
system_image_package="system-images;android-${api_level};${img_type};${architecture}"
avd_config_template=/tmp/config.ini.template
avd_config_path="${ANDROID_AVD_HOME}/${avd_name}.avd/config.ini"

# Install runtime dependencies of the emulator/qemu binaries and their graphics, audio and
# ADB-forwarding stacks (alphanumerically sorted; `apk search` misses some of these, e.g.
# libbsd, so this list was verified via `ldd`, not `apk search`).
apk add --no-cache \
    alsa-lib \
    dbus-libs \
    libbsd \
    libdrm \
    libpulse \
    libuuid \
    libx11 \
    libxcb \
    libxcursor \
    libxext \
    libxi \
    libxkbcommon \
    libxrender \
    libxshmfence \
    mesa-dri-gallium \
    mesa-gbm \
    mesa-gl \
    nss \
    socat \
    xvfb

# `yes` receives SIGPIPE once sdkmanager stops reading stdin, which `set -o pipefail` would
# otherwise treat as a pipeline failure even though sdkmanager itself succeeded. Disable
# pipefail for this one command; sdkmanager's own exit status still fails the build below
# via `set -e` on the enclosing command.
set +o pipefail
yes | sdkmanager --licenses
set -o pipefail

sdkmanager --install "emulator" "${system_image_package}" --channel=0

installed_emulator_version=$(grep "Pkg.Revision" "${ANDROID_HOME}/emulator/source.properties" | cut -d'=' -f2)
if [ "${installed_emulator_version}" != "${expected_emulator_version}" ]; then
    echo "Error: installed emulator version '${installed_emulator_version}' does not match" >&2
    echo "expected version '${expected_emulator_version}'." >&2
    echo "Bump ANDROID_EMULATOR_VERSION in versions.env to '${installed_emulator_version}' (Renovate normally does this)." >&2
    exit 1
fi

mkdir -p "${ANDROID_AVD_HOME}"
echo no | avdmanager create avd --force --name "${avd_name}" --package "${system_image_package}"

# Replace the avdmanager-generated config.ini wholesale with our tuned, parameterized
# template (fixes the old repo's defect of a hardcoded API level/abi baked for one image
# only). sed, not envsubst: gettext is not installed in the base image.
sed \
    -e "s/@API_LEVEL@/${api_level}/g" \
    -e "s/@ARCHITECTURE@/${architecture}/g" \
    -e "s/@CORES@/${cores}/g" \
    -e "s/@DATA_PARTITION_SIZE@/${data_partition_size}/g" \
    -e "s/@IMG_TYPE@/${img_type}/g" \
    -e "s/@LCD_DENSITY@/${lcd_density}/g" \
    -e "s/@LCD_HEIGHT@/${lcd_height}/g" \
    -e "s/@LCD_WIDTH@/${lcd_width}/g" \
    -e "s/@RAM_MB@/${ram_mb}/g" \
    "${avd_config_template}" >"${avd_config_path}"

# Pre-warm the new `android` CLI bootstrapper so pipelines never pay its ~235 MB
# first-run download. NEVER call `android update`: that would make the build depend on a
# self-updating v1.0 tool and break reproducibility.
android --no-metrics --version
if [ ! -d "${ANDROID_USER_HOME}/bin" ] || [ ! -d "${ANDROID_USER_HOME}/cli" ]; then
    echo "Error: 'android --no-metrics --version' did not install its payload under" >&2
    echo "'${ANDROID_USER_HOME}'. Check that ANDROID_USER_HOME is set before this step runs." >&2
    exit 1
fi
android-tools disable-metrics

# Cleanup (same layer as the installs above, alphanumerically sorted).
rm -rf \
    "${ANDROID_HOME}/.downloadIntermediates" \
    "${ANDROID_HOME}/.patches" \
    "${ANDROID_HOME}/.temp" \
    "${ANDROID_USER_HOME}/cache"

chgrp -R 0 "${ANDROID_HOME}" "${ANDROID_SDK_HOME}" "${ANDROID_AVD_HOME}"
chmod -R g=u "${ANDROID_HOME}" "${ANDROID_SDK_HOME}" "${ANDROID_AVD_HOME}"
