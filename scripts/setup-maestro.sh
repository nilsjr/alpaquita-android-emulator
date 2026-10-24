#!/usr/bin/env bash
set -euo pipefail

maestro_version=$1

maestro_archive_path=/tmp/maestro.zip
maestro_binary_path=/opt/maestro/bin/maestro

curl -fsSL --retry 5 \
    "https://github.com/mobile-dev-inc/maestro/releases/download/cli-${maestro_version}/maestro.zip" \
    -o "${maestro_archive_path}" \
    -w "Downloaded: %{url_effective}\n"
unzip -q "${maestro_archive_path}" -d /opt
rm "${maestro_archive_path}"

# Throwaway home for the version check: baking .maestro under /opt/android/user would leave
# root-owned state there that arbitrary UIDs cannot write, and a cache mount would mask it.
build_time_home=$(mktemp -d)
installed_version_output=$(MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true MAESTRO_OPTS="-Duser.home=${build_time_home}" "${maestro_binary_path}" --version)
rm -rf "${build_time_home}"
if ! grep -q "${maestro_version}" <<<"${installed_version_output}"; then
    echo "Error: '${maestro_binary_path} --version' printed '${installed_version_output}'," >&2
    echo "which does not contain the expected version '${maestro_version}'." >&2
    echo "Bump MAESTRO_VERSION in versions.env, or check that release cli-${maestro_version} exists." >&2
    exit 1
fi

chgrp -R 0 /opt/maestro
chmod -R g=u /opt/maestro
