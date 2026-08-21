#!/usr/bin/env bash
set -euo pipefail

# Resolves the STABLE-channel Android emulator version + build id from Google's
# repository XML, then asserts every requested API level still has a published
# google_atd x86_64 system image. The SDK *platform* and the emulator *system image*
# are versioned independently, so a platform release does not imply a bootable system
# image exists yet — that ceiling must be asserted, not assumed.
#
# Usage: fetch-emulator-version.sh <comma-separated-api-levels>
# Prints: "<version> <build_id>" on success, e.g. "37.1.11 15917651"

api_levels_csv=$1
repository_xml_url="https://dl.google.com/android/repository/repository2-3.xml"
sysimg_xml_url="https://dl.google.com/android/repository/sys-img/google_atd/sys-img2-3.xml"

repository_xml=$(curl -fsSL "$repository_xml_url")

stable_channel_id=$(grep -oP '<channel id="(channel-[0-9]+)">stable</channel>' <<<"$repository_xml" |
    grep -oP 'channel-[0-9]+' | head -n1)

if [[ -z "$stable_channel_id" ]]; then
    echo "ERROR: could not find the stable channel id in $repository_xml_url" >&2
    exit 1
fi

# Scan every <remotePackage path="emulator"> block (dev/beta/stable/canary are listed
# back-to-back) and keep the one whose channelRef matches the stable channel.
result=$(awk -v channel="$stable_channel_id" '
    /<remotePackage path="emulator">/ { in_pkg=1; major=""; minor=""; micro=""; matched=0; build=""; next }
    in_pkg && /<major>/ { line=$0; gsub(/[^0-9]/, "", line); major=line }
    in_pkg && /<minor>/ { line=$0; gsub(/[^0-9]/, "", line); minor=line }
    in_pkg && /<micro>/ { line=$0; gsub(/[^0-9]/, "", line); micro=line }
    in_pkg && $0 ~ "<channelRef ref=\"" channel "\"/>" { matched=1 }
    in_pkg && /emulator-linux_x64-[0-9]+\.zip/ {
        line=$0
        sub(/.*emulator-linux_x64-/, "", line)
        sub(/\.zip.*/, "", line)
        build=line
    }
    in_pkg && /<\/remotePackage>/ {
        if (matched == 1 && build != "") {
            print major "." minor "." micro " " build
            exit
        }
        in_pkg=0
    }
' <<<"$repository_xml")

if [[ -z "$result" ]]; then
    echo "ERROR: could not resolve the stable-channel emulator package from $repository_xml_url" >&2
    exit 1
fi

sysimg_xml=$(curl -fsSL "$sysimg_xml_url")

missing_api_levels=()
IFS=',' read -ra api_levels <<<"$api_levels_csv"
for api_level in "${api_levels[@]}"; do
    package_path="system-images;android-${api_level};google_atd;x86_64"
    if ! grep -qF "path=\"${package_path}\"" <<<"$sysimg_xml"; then
        missing_api_levels+=("$api_level")
    fi
done

if [[ ${#missing_api_levels[@]} -gt 0 ]]; then
    echo "ERROR: no google_atd x86_64 system image published for API level(s): ${missing_api_levels[*]}" >&2
    echo "The SDK platform can ship ahead of the system image; only the system image is bootable." >&2
    echo "Lower EMULATOR_API_LEVELS in versions.env until Google publishes these images." >&2
    exit 1
fi

echo "$result"
