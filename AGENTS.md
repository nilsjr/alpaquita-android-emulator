# Android CI Build-Image Style Guide

# Project Purpose
This repository maintains a specialized, high-performance Docker image designed exclusively for CI agents to build Android projects.

## Core Technical Pillars
* **Minimal Footprint:** Reduce image pull latency through aggressive layer optimization and zstandard (zstd) compression.
* **Maximum Build Speed:** Integration of `mimalloc` to accelerate memory-intensive processes (Gradle, Kotlin compiler).
* **Tooling Excellence:** Ensure the latest stable Android SDKs, build tools, and essential CLI utilities are provided in a pre-configured state.
* **Autonomous Maintenance:** Fully self-updating lifecycle via Renovate and Automerge.

## Runtime & Orchestration
* **CI/CD Platform:** The entire pipeline, from validation to deployment, is powered by **GitHub Actions**. Use Composite Actions to encapsulate modular logic and maintain clean workflow YAMLs.
* **Execution Environment:** The resulting image is designed to run on **Kubernetes** orchestrated by a **Jenkins Controller** using **Jenkins Agents**.

## Permissions & UID Agnosticism
* **Arbitrary UID Support:** The image must be executable by any arbitrary UID to support restricted Kubernetes environments (e.g., `runAsNonRoot: true` or specific `runAsUser` contexts).
* **GID 0 Strategy:** Adhere to the **OpenShift/Kubernetes GID 0 pattern**. All defined Android and Gradle directories must be owned by the root group (`chgrp -R 0`) with group permissions mirroring owner permissions (`chmod -R g=u`). This ensures arbitrary-UID CI containers have full read/write access to the following paths:
  * **Tooling (`ANDROID_HOME`):** Contains the Android SDK, build tools, and platform tools.
  * **User State (`ANDROID_SDK_HOME`):** Parent directory for stateful data, including:
    * `ANDROID_USER_HOME`: Stores Android-specific configurations and keys.
    * `GRADLE_USER_HOME`: Stores build caches, dependencies, and daemon logs.
* **Agnostic Home:** Redirect all stateful data (Gradle caches, Android configs) to a neutral path (`/opt/android/user`) instead of the standard `/root` or `/home`. This ensures portability and simplifies volume mounting for persistent CI caching.

# Autonomous Maintenance (Renovate)
* **Automerge:** PRs from Renovate are automatically merged if the CI pipeline (Dry-Run) passes.
* **Validation:** Automated validation (Trivy, Dive) is mandatory to replace human intervention.
* **Release Trigger:** Merges to main trigger an automated release and registry push via GitHub Actions.

# Technical Standards
## Scripting
* **POSIX Shell (sh):** Mandatory for bootstrap scripts (e.g., initial setup) before `bash` is available. Use `#!/bin/sh` and `set -eu`.
* **Bash:** Preferred for all CI orchestration. Use `#!/usr/bin/env bash` with `set -euo pipefail`.
* **Decoupling:** Scripts must be portable. Pass output paths as parameters; do not rely on CI-specific environment variables for core logic.
* **Self-Documenting Code:** Code and variables must be self-explanatory. Use descriptive names that convey intent.
* **Comments:** Use comments sparingly. Only use them to explain the "why" behind complex logic, not the "what".
* **Language:** All code, comments, and documentation must be in English.

## Docker Architecture
* **Reproducible Builds:** Ensure consistency across environments through deterministic build steps.
* **Version & Digest Pinning:** Explicitly pin versions and SHA-256 digests for all base images to ensure immutability (e.g., `image:tag@sha256:...`). This is enforced by Renovate as configured in `.github/renovate.json5`.
* **Layer Optimization:**
  * **Alphanumeric Sorting:** Sort multi-line arguments (e.g., packages in `apt-get install`, labels, or environment variables) alphanumerically to avoid duplicates and improve PR readability.
  * **Atomic RUN Commands:** Always combine `update` and `install` instructions (e.g., `apt-get update && apt-get install -y --no-install-recommends ...`) to prevent caching issues.
  * **Minimalism:** Use `--no-install-recommends` for all package managers and clean up caches (e.g., `rm -rf /var/lib/apt/lists/*`) within the same `RUN` layer.
* **Robust Execution:**
  * **Pipefail:** Prepend `set -o pipefail` to all `RUN` instructions involving pipes (`|`) to ensure build failures if any command in the chain fails.
  * **Exec Form:** Use the **JSON Array/Exec Form** (`["executable", "param"]`) for `ENTRYPOINT` and `CMD` to ensure proper signal handling (PID 1).
* **Environment & Pathing:**
  * **Workdir:** Always use absolute paths for `WORKDIR`. Avoid using `RUN cd ...`.
  * **Allocators:** `mimalloc` must be preloaded via `LD_PRELOAD` to optimize tool performance.
* **Compression:** Use `zstd` (level 9) with `force-compression=true` for registry exports.

# Formatting & Tooling
* **EditorConfig:** Source of truth for indentation and line endings (enforced via `.editorconfig`).
* **Linters & Formatters:**
  * `shfmt`: Mandatory for formatting shell scripts. Use settings that respect `.editorconfig`.
  * `shellcheck`: Mandatory for static analysis of `.sh` and `.bash` files.
  * `hadolint`: Mandatory for Dockerfile best practices.
  * `yamllint`: Mandatory for YAML files using `.github/.yamllint.yaml`.
* **Analysis:** Every build must be verified by `dive` for layer efficiency.

# CI/CD Strategy (GitHub Actions)
* **Dry-Run:** Build `linux/amd64` only for rapid feedback and security scanning on feature branches and pull requests.
* **Registry Authentication:** Secure authentication via GitHub Secrets to target container registries.
* **Two-Stage Release Logic:**
  1. **Push to main (Version Generation):** Merges to `main` evaluate the git commit history since the last tag. If Conventional Commits contain semantic changes (`feat` or `fix`), a new version tag is automatically generated and pushed. Non-semantic changes (e.g., CI-only dependency updates) will not trigger a new tag.
  2. **Push of a Git Tag (Release Execution):** The workflow switches to the release environment when triggered by a new version tag. It executes the full build (`linux/amd64`), pushes the verified images to the designated registries, and automatically generates the GitHub Release.
* **Concurrency:** Use a conditional grouping strategy:
  * Tags and releases must use a unique `run_id` group to ensure atomicity and prevent cancellation.
  * Standard workflows (main/PRs) must use a branch-based group with `cancel-in-progress: true` to optimize runner usage.

# Emulator & Maestro Extensions

This repository builds `FROM` the pinned upstream image described above and adds a hardware-accelerated
Android emulator, plus an optional Maestro CLI layer on top. Everything above still applies; the rules
below are additive and specific to the emulator/Maestro surface. See `CONTRACT.md`-derived decisions in
the handover spec for the full rationale — this section states the resulting *rules*, not the analysis.

## AVD Placement — `ANDROID_AVD_HOME` Lives Outside `ANDROID_SDK_HOME`
* `ANDROID_AVD_HOME=/opt/android/user` would look like the obvious choice — it is not the one we use.
  `ANDROID_AVD_HOME=/opt/android/avd` is a GID-0'd **sibling** of `/opt/android/user`
  (`ANDROID_SDK_HOME`), deliberately outside that subtree.
* **Why this matters more than it looks:** the production Jenkins pod mounts a cache volume over the
  *entire* `/opt/android/user` directory. Anything baked under that path — including a pre-created AVD
  or the pre-warmed `android` CLI payload (see below) — would be silently masked at container start.
  No error, no log line: just a missing AVD (`avdmanager list` shows nothing) and a 235 MB re-download
  on every single job. This is exactly the class of bug that is expensive to diagnose because the image
  looks correct in isolation and only breaks once mounted the way production actually mounts it.
* **Rule:** never move the AVD back under `ANDROID_SDK_HOME`. If a pod ever needs a persistent cache
  volume in the emulator container, mount the narrow `${GRADLE_USER_HOME}` path
  (`/opt/android/user/.gradle`), never the whole user directory. Document this trap in the README, not
  just here — it is the single highest-severity operational risk in this project.

## `emulator-tools` Is a Stable Public Contract
* `emulator-tools start|wait-ready|stop|status|disable-animations` is consumed directly by the
  Dockerfile (`HEALTHCHECK`, `emulator-entrypoint`) and by CI's smoke tests. Its subcommand names, exit
  codes, and `wait-ready`'s non-zero-on-timeout behavior are the public surface of this project. Do not
  rename, remove, or silently change the semantics of a subcommand without updating every consumer in
  the same change.
* The JSON state log lines (`{"type":"state-update","value":"ANDROID_READY"}`) are human-readable log
  output, not a machine-parsed contract today — keep emitting them anyway. They are cheap, and a
  downstream pipeline may start depending on them later.

## Provisioning Uses `sdkmanager` / `avdmanager` — Never the New `android` CLI
* Build-time installation of the emulator package and system image, and AVD creation, goes exclusively
  through the legacy `sdkmanager` / `avdmanager`. They are deterministic, version-pinnable, and add no
  network bootstrap of their own.
* The new unified `android` CLI (shipped in `cmdline-tools`) is genuinely nicer, but at v1.0 it
  self-downloads a 235 MB payload on first invocation and ships a self-update path. That combination is
  the wrong foundation for a reproducible build. Pre-warm it in the build layer (one
  `android --no-metrics --version` call) purely so pipelines are not surprised by that download at
  runtime — it stays optional and non-load-bearing.
* **Never call `android update`, and never let the CLI self-update at runtime.** Reproducibility depends
  on this. If `emulator-tools` ever delegates to `android emulator start` as a convenience, the
  `adb`-based path must remain the fallback.

## The API-36 System-Image Ceiling
* The SDK **platform** version and the emulator **system image** version are independent axes. The base
  image may compile against a newer platform, but as of this writing Google has not published a system
  image past **API 36** for any image type (`google_atd`, `aosp_atd`, `google_apis`).
  `EMULATOR_API_LEVELS` in `versions.env` must never list an API level above that ceiling.
* CI asserts this via the `emulator-version-fetcher` action instead of assuming it, so the day Google
  publishes an API 37 system image, the assertion — not a stale comment — is what surfaces it.

## Animations and the Hidden-API Policy Are Off/On By Default
* `EMULATOR_DISABLE_ANIMATIONS=true` and `EMULATOR_HIDDEN_API_POLICY=true` are the baked defaults. Both
  exist to make UI-test runs (Maestro, Espresso, instrumented tests) deterministic. Do not flip either
  default: the old image left them unset, which meant every consuming pipeline had to re-apply the same
  three `settings put global *_animation_scale 0` calls by hand, every run.

## Maestro Is Pinned via Renovate, Never Installed on the Fly
* The `-maestro` variant bakes one specific `MAESTRO_VERSION` from `versions.env` at build time. Never
  add a runtime step that downloads or upgrades Maestro inside a running container — that reintroduces
  the unpinned, network-dependent install the old pipeline had to work around on every build.
* Renovate tracks new releases via the `github-releases` datasource against `mobile-dev-inc/maestro` and
  bumps `versions.env` accordingly; the image never tracks a "latest" moving target internally.

## Baseline Profiles: Generation Only, Never a Performance Gate
* This image supports **baseline-profile generation** on the emulator (Gradle Managed Device /
  `profgen`). It does **not** support Macrobenchmark *measurement* — Google's own tooling returns errors
  when measuring on an emulator, precisely because the numbers would not represent a real device.
* Never wire a performance or regression gate onto this image. If a request for one comes in, redirect
  it to physical-device benchmarking and state the scope limit in the README, not only here.
