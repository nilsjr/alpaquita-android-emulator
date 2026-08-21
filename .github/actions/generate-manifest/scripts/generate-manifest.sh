#!/usr/bin/env bash
set -euo pipefail

image=$1
image_tag=$2
report_file=$3

get_sdk_components() {
    docker run --rm "$image" sdkmanager --list_installed 2>/dev/null |
        awk -F '|' '
        /^[[:space:]]*(Path|---)/ { next }
        /^[[:space:]]+[a-zA-Z0-9.;_-]+[[:space:]]+\|/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);
            printf "| %s | %s | %s |\n", $1, $2, $3
        }' | sort
}

get_apk_packages() {
    docker run --rm "$image" apk info -v 2>/dev/null |
        awk '
        /^WARNING:/ { next }
        /^[a-zA-Z0-9]/ {
            full=$0; pkg=$0;
            sub(/-[0-9].*$/, "", pkg);
            ver=substr(full, length(pkg) + 2);
            printf "| %s | %s |\n", pkg, ver
        }' | sort
}

# Authoritative install version, straight from the SDK package's own metadata — the
# same file setup-emulator.sh asserts against at build time (handover §5.2 defect #4:
# never ship a config value that does not reflect what actually got installed).
get_emulator_version() {
    docker run --rm "$image" sh -c \
        'grep "^Pkg.Revision" "${ANDROID_HOME}/emulator/source.properties" 2>/dev/null | cut -d= -f2' |
        tr -d '\r'
}

# Pull just the system-images row out of the same sdkmanager listing used above, so
# it is visible at a glance without scrolling the full component table.
get_system_image_row() {
    docker run --rm "$image" sdkmanager --list_installed 2>/dev/null |
        awk -F '|' '
        /system-images;/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
            print $1 " (" $2 ")"
        }' | head -n1
}

# The baked AVD profile (handover §5.3): name plus the ram/cores/resolution knobs
# that matter most for CI boot time and Maestro visibility.
get_avd_summary() {
    local config
    config=$(docker run --rm "$image" sh -c \
        'cat "${ANDROID_AVD_HOME}/${EMULATOR_AVD_NAME}.avd/config.ini" 2>/dev/null')
    [[ -z "$config" ]] && return 0

    local name ram cores width height density
    name=$(grep '^AvdId=' <<<"$config" | cut -d= -f2)
    ram=$(grep '^hw.ramSize=' <<<"$config" | cut -d= -f2)
    cores=$(grep '^hw.cpu.ncore=' <<<"$config" | cut -d= -f2)
    width=$(grep '^hw.lcd.width=' <<<"$config" | cut -d= -f2)
    height=$(grep '^hw.lcd.height=' <<<"$config" | cut -d= -f2)
    density=$(grep '^hw.lcd.density=' <<<"$config" | cut -d= -f2)

    echo "${name} — ${width}x${height}@${density}dpi, ${ram}MB RAM, ${cores} cores"
}

# Only present in the maestro variant; an empty result means "omit the row".
get_maestro_version() {
    docker run --rm "$image" sh -c \
        'command -v maestro >/dev/null 2>&1 && maestro --version' 2>/dev/null
}

generate_markdown_body() {
    local emulator_version system_image_row avd_summary maestro_version

    emulator_version=$(get_emulator_version)
    system_image_row=$(get_system_image_row)
    avd_summary=$(get_avd_summary)
    maestro_version=$(get_maestro_version)

    cat <<EOF
<details><summary><b>🐋 Docker Image Content: <code>${image_tag}</code></b></summary>

#### 🎮 Emulator Configuration
| Property | Value |
| :--- | :--- |
| Emulator Version | ${emulator_version:-N/A} |
| System Image | ${system_image_row:-N/A} |
| AVD Profile | ${avd_summary:-N/A} |
EOF

    if [[ -n "$maestro_version" ]]; then
        echo "| Maestro Version | ${maestro_version} |"
    fi

    cat <<EOF

#### 🤖 Android SDK Components
| Component | Version | Description |
| :--- | :--- | :--- |
$(get_sdk_components)

#### 📦 Installed OS Packages (apk)
<details><summary>Click to view APK list</summary>

| Package | Version |
| :--- | :--- |
$(get_apk_packages)

</details>
</details>

EOF
}

generate_markdown_body >>"$report_file"
