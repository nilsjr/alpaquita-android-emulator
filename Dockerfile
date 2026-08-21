# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=experimental=all;error=true

# VARIANT selects the published stage (emulator|maestro); global-scope on purpose — only global args are visible to FROM expansion
ARG VARIANT=emulator

FROM g00fy2/alpaquita-android:android-37.1-jdk26-v2026.7.0@sha256:3834a836a4aaab4901ceabef8aab593df33f7eeff5d53e2c17082753e91c33af AS emulator

ARG ANDROID_EMULATOR_VERSION
ARG API_LEVEL=34
ARG ARCHITECTURE=x86_64
ARG CORES=4
ARG DATA_PARTITION_SIZE=8G
ARG IMG_TYPE=google_atd
ARG LCD_DENSITY=440
ARG LCD_HEIGHT=2280
ARG LCD_WIDTH=1080
ARG RAM_MB=4096

LABEL org.opencontainers.image.description="Alpaquita Android CI image with a hardware-accelerated Android emulator baked in." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/nilsjrfn/alpaquita-android-emulator" \
      org.opencontainers.image.title="Alpaquita Android Emulator"

# ANDROID_AVD_HOME sits outside ANDROID_SDK_HOME on purpose: a k8s cache volume mounted
# over ANDROID_SDK_HOME must not mask the AVD baked at build time (mount-trap avoided).
ENV ADB_EXPOSE=false
ENV ANDROID_AVD_HOME=/opt/android/avd
ENV API_LEVEL=${API_LEVEL}
ENV EMULATOR_AVD_NAME=android-ci
ENV EMULATOR_BOOT_TIMEOUT=600
ENV EMULATOR_CORES=${CORES}
ENV EMULATOR_DISABLE_ANIMATIONS=true
ENV EMULATOR_HIDDEN_API_POLICY=true
ENV EMULATOR_WIPE_DATA=false
ENV GPU_ACCELERATED=false
ENV PATH=${PATH}:${ANDROID_HOME}/emulator
# Left intentionally unset (runtime-overridable, scripts fall back internally):
# EMULATOR_LOCALE, EMULATOR_RAM_MB, EMULATOR_EXTRA_ARGS, EMULATOR_REQUIRE_KVM (defaults to true when unset).

RUN --mount=type=bind,source=scripts/setup-emulator.sh,target=/tmp/setup-emulator.sh \
    --mount=type=bind,source=avd/config.ini.template,target=/tmp/config.ini.template \
    --mount=type=bind,source=scripts/emulator-entrypoint.sh,target=/tmp/emulator-entrypoint.sh \
    --mount=type=bind,source=scripts/emulator-lib.sh,target=/tmp/emulator-lib.sh \
    --mount=type=bind,source=scripts/emulator-tools,target=/tmp/emulator-tools \
    --mount=type=bind,source=scripts/healthcheck.sh,target=/tmp/healthcheck.sh \
    /bin/bash /tmp/setup-emulator.sh \
    "${API_LEVEL}" "${IMG_TYPE}" "${ARCHITECTURE}" "${ANDROID_EMULATOR_VERSION}" \
    "${RAM_MB}" "${CORES}" "${DATA_PARTITION_SIZE}" "${LCD_WIDTH}" "${LCD_HEIGHT}" "${LCD_DENSITY}" && \
    cp /tmp/emulator-entrypoint.sh /usr/local/bin/emulator-entrypoint && \
    cp /tmp/emulator-lib.sh /usr/local/bin/emulator-lib.sh && \
    cp /tmp/emulator-tools /usr/local/bin/emulator-tools && \
    cp /tmp/healthcheck.sh /usr/local/bin/emulator-healthcheck && \
    chmod 755 \
    /usr/local/bin/emulator-entrypoint \
    /usr/local/bin/emulator-healthcheck \
    /usr/local/bin/emulator-lib.sh \
    /usr/local/bin/emulator-tools

EXPOSE 5554 5555

HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 CMD ["emulator-healthcheck"]

CMD ["/bin/bash"]

FROM emulator AS maestro

ARG MAESTRO_VERSION

ENV MAESTRO_CLI_NO_ANALYTICS=1
ENV PATH=/opt/maestro/bin:${PATH}

# Builds on top of the already-provisioned "emulator" stage; must not re-run emulator
# provisioning (setup-emulator.sh), only add the Maestro CLI.
RUN --mount=type=bind,source=scripts/setup-maestro.sh,target=/tmp/setup-maestro.sh \
    /bin/bash /tmp/setup-maestro.sh "${MAESTRO_VERSION}"

# final The published stage; CI selects it via --build-arg VARIANT=emulator|maestro
FROM ${VARIANT} AS final
