# Alpaquita Android Emulator

Hardware-accelerated Android emulator CI images, built `FROM`
[G00fY2/alpaquita-android](https://github.com/G00fY2/alpaquita-android) — minimal, `glibc`-based,
`mimalloc`-accelerated Java/Kotlin build images that explicitly ship *without* an emulator. This
repository adds the missing piece: a booting, ADB-reachable, KVM-accelerated Android emulator, plus an
optional [Maestro](https://docs.maestro.dev/) CLI layer, so one container can compile an Android app
*and* run its UI tests.

#### [Docker Hub](https://hub.docker.com/r/nilsjrfn/alpaquita-android-emulator)

```bash
docker pull nilsjrfn/alpaquita-android-emulator:latest
```

> [!TIP]
> Available images and their exact contents (emulator build-id, system image, Maestro version) are
> listed in the latest [GitHub Release](https://github.com/nilsjrfn/alpaquita-android-emulator/releases/latest) —
> generated from the same manifest that upstream produces.

## What this is, and why

The Android Jenkins pipeline that runs today compiles apps *and* runs Maestro UI tests, using
`nilsjrfn/docker-android:api-34` — the image produced by the now-archived
[`nilsjrfn/maestro-emulator`](https://github.com/nilsjrfn/maestro-emulator) repo. That image works; this
project is an **evolution**, not a rescue: same job (build + boot + test in one container), rebuilt on a
better foundation, with its real defects fixed rather than carried forward.

The foundation is upstream's own stated gap:

> **Not included:** Android NDK and the Android Emulator. […] dedicated NDK/Emulator variants are
> planned.

This repository is that planned emulator variant. It stays a thin, additive layer on top of the pinned
upstream image — the Java/Kotlin build story (JDK, `mimalloc`, GID 0, `ANDROID_HOME` /
`GRADLE_USER_HOME`) is entirely inherited, not reimplemented.

> [!IMPORTANT]
> **Scope:** this image supports **baseline-profile generation**, not Macrobenchmark *measurement*.
> Google's own Macrobenchmark tooling errors out when it detects an emulator — timing numbers from a
> virtual device are not representative of a real one. See [Baseline profiles](#baseline-profiles) below.
> Do not wire a performance/regression gate onto this image.

## Image matrix & tag scheme

The matrix is **API level × variant**, capped at **API 36** — Google has not published a system image
above 36 for any image type (`google_atd`, `aosp_atd`, `google_apis`), even though newer SDK *platforms*
exist. The emulator's system-image API level and the base image's compile-time platform API level are
independent; do not confuse the two.

| API | Why it's in the matrix | Default system image |
| :-- | :--- | :--- |
| **36** | Highest bootable level today; catches new-platform behavior early; receives the `latest` tag. | `google_atd` |
| **34** | Continuity with the current production baseline (`api-34`); the baseline-profile generation level. | `google_atd` (an `aosp_atd` build is also produced for the baseline-profile job) |

`EMULATOR_API_LEVELS` in [`versions.env`](versions.env) is the single source of truth for the published
API levels; its first (leftmost) entry is the one that receives `latest`.

| Tag pattern | Rolling / immutable | Meaning |
| :--- | :--- | :--- |
| `android-<api>-emulator` | rolling | Latest build for that API level, emulator only. |
| `android-<api>-emulator-maestro` | rolling | Same, plus the pinned Maestro CLI. |
| `android-<api>-emulator-v<year>.<rel>.<patch>` | **immutable** | Pin this in production/CI pipelines. |
| `android-<api>-emulator-maestro-v<year>.<rel>.<patch>` | **immutable** | Same, plus Maestro. |
| `latest` | rolling | API 36, `emulator` variant. |

Docker Hub namespace: **`nilsjrfn/alpaquita-android-emulator`** (GHCR is not used for this image — the
production cluster's pull-through mirror resolves the Docker Hub path).

## Usage

There are three ways to run this image, matching the three places it actually gets used.

### 1. Build agent (compile + test in one container)

The default mode — `CMD ["/bin/bash"]`, no `ENTRYPOINT`, same idiom as upstream. Start the emulator
explicitly, then use the container as a normal build agent:

```bash
docker run --rm -it --device /dev/kvm \
  nilsjrfn/alpaquita-android-emulator:android-34-emulator-maestro

emulator-tools start --wait          # boots the AVD, blocks until sys.boot_completed=1
./gradlew connectedAndroidTest       # or: assembleDebug, etc.
maestro test .maestro/flows/         # only on the -maestro variant
```

`emulator-tools start` returns immediately; `emulator-tools start --wait` (or `start` followed by
`wait-ready`) blocks until the device is actually usable — this is the fix for the old image's broken
boot-poll (it discarded `adb wait-for-device`'s exit status, so the wait loop never actually waited).

### 2. Appliance (the container *is* the emulator)

For `docker run --entrypoint`, or any orchestrator that expects a container to block for its own
lifetime:

```bash
docker run --rm -d --device /dev/kvm -p 5554:5554 -p 5555:5555 \
  --entrypoint emulator-entrypoint \
  nilsjrfn/alpaquita-android-emulator:android-36-emulator

adb connect localhost:5555
```

`emulator-entrypoint` runs as PID 1, traps `SIGTERM`/`SIGINT` to shut the emulator down cleanly, starts
the emulator and waits for boot, then blocks on the emulator log/process so the container stays alive for
as long as the emulator does — and exits non-zero if the emulator dies underneath it.

### 3. Kubernetes sidecar (ADB over the pod network)

When the emulator needs to be reachable from a *different* container or pod than the one that boots it —
a shared device-farm-style pod, for example — expose ADB over the pod's own network address instead of
only `127.0.0.1`:

```bash
docker run --rm -d --device /dev/kvm -e ADB_EXPOSE=true \
  nilsjrfn/alpaquita-android-emulator:android-36-emulator
```

With `ADB_EXPOSE=true`, `emulator-tools start` runs `socat` forwarders that relay the container's `eth0`
address on ports `5554`/`5555` to the emulator bound on `127.0.0.1`. Leave it `false` (the default) when
the ADB client lives in the same container as the emulator — that is the common case, and `socat` would
be pure overhead there. This is opt-in on purpose: the old image ran `adb start-server` and both `socat`
forwarders at *build* time, inside a layer that no longer exists once the container starts — a defect
fixed by moving all of this into the runtime entrypoint where it belongs.

## Runtime environment variables

All of these are set as `ENV` in the image (with the defaults below) and are overridable at
`docker run` / in a pod spec via `-e` / `env:`.

| Variable | Default | Meaning |
| :--- | :--- | :--- |
| `ADB_EXPOSE` | `false` | Forward ADB (`5555`) and the console (`5554`) via `socat` from the container's own network address — only needed for the sidecar pattern (see above). |
| `ANDROID_AVD_HOME` | `/opt/android/avd` | Where the baked AVD lives. Technically overridable, but never should be — see [Kubernetes guidance](#kubernetes-guidance) for why. |
| `API_LEVEL` | *(baked per tag, e.g. `36` or `34`)* | The system-image API level this tag was built for. Informational; not meant to be changed at runtime. |
| `EMULATOR_AVD_NAME` | `android-ci` | Name of the AVD `emulator-tools` boots. |
| `EMULATOR_BOOT_TIMEOUT` | `600` (seconds) | Deadline for `emulator-tools wait-ready`; exits non-zero and dumps the last 50 log lines on timeout. |
| `EMULATOR_CORES` | `4` (baked from the `CORES` build arg) | vCPUs passed to `emulator -cores`. |
| `EMULATOR_DISABLE_ANIMATIONS` | `true` | After boot, zero out the three `*_animation_scale` settings for deterministic UI tests. |
| `EMULATOR_HIDDEN_API_POLICY` | `true` | After boot, set `hidden_api_policy*` to `1`. |
| `EMULATOR_WIPE_DATA` | `false` | Adds `-wipe-data` on launch when `true`. Off by default so the baked data partition survives across boots — the old image wiped on every boot, which cost minutes per run for nothing. |
| `EMULATOR_LOCALE` | *(unset)* | Passed as `-change-locale <value>` at emulator launch; `wait-ready` returns only once the device is back up in that locale. See [FAQ](#faq). |
| `EMULATOR_RAM_MB` | *(unset)* | When set, adds `-memory <value>` on launch. Unset means the AVD's baked `hw.ramSize` (`4096` by default) applies. |
| `EMULATOR_EXTRA_ARGS` | *(unset)* | Appended verbatim to the `emulator` command line, for one-off flags not otherwise exposed. |
| `EMULATOR_REQUIRE_KVM` | `true` | `emulator-tools start` runs `emulator -accel-check` first and fails fast with an actionable message if it doesn't pass. Set to `false` only to deliberately allow an unaccelerated (very slow) boot. |
| `GPU_ACCELERATED` | `false` | When `true`, starts `Xvfb :0.0` and boots with `-gpu host`. When `false`, boots with `-gpu swiftshader_indirect` (software rendering — fine for most UI tests, and the only option without a real GPU behind KVM). |
| `GPU_MODE` | *(unset)* | Overrides the `-gpu` value `GPU_ACCELERATED` would otherwise select, for the rare case neither `host` nor `swiftshader_indirect` is right. |
| `MAESTRO_CLI_NO_ANALYTICS` | `1` (maestro variant only) | Disables Maestro CLI telemetry; matches what the production pipeline already sets today. |

Baked at build time as Docker build `ARG`s (not runtime env vars — see the Dockerfile if you need to
build a custom variant): `API_LEVEL`, `IMG_TYPE`, `ARCHITECTURE`, `ANDROID_EMULATOR_VERSION`, `RAM_MB`,
`CORES`, `DATA_PARTITION_SIZE`, `LCD_WIDTH`, `LCD_HEIGHT`, `LCD_DENSITY`, `MAESTRO_VERSION`, `VARIANT`.

## KVM requirements

The emulator needs `/dev/kvm` for hardware acceleration — without it, boot times move from seconds to
minutes and CI becomes impractical. Grant it one of two ways:

```bash
# Narrow: mount just the device node
docker run --device /dev/kvm ...

# Broad: full privileged mode (what the current production pod actually uses today)
docker run --privileged ...
```

`emulator-tools start` runs `emulator -accel-check` as a preflight before launching anything. If
`/dev/kvm` is missing or inaccessible and `EMULATOR_REQUIRE_KVM` is not explicitly `false`, it fails
immediately with an actionable message instead of the old behavior of hanging for the full boot timeout.

## Kubernetes guidance

> [!WARNING]
> **Never mount a volume over `/opt/android/user`.** This is the single highest-severity operational
> trap in this project, and it fails silently.
>
> Upstream's `ANDROID_SDK_HOME` (`/opt/android/user`) is exactly the path a caching setup would
> intuitively mount a volume over. If you do that here, the mount masks everything baked under it —
> including the pre-warmed `android` CLI (235 MB, otherwise re-downloaded on every job) — with no error
> at all. This is why the AVD itself lives at **`ANDROID_AVD_HOME=/opt/android/avd`**, a sibling
> directory outside `/opt/android/user`: mounting over the user directory cannot take the AVD down with
> it. If a pod genuinely needs a persistent cache volume, mount the narrower
> `/opt/android/user/.gradle` (`GRADLE_USER_HOME`) instead of the whole user directory.

Pod `command:` matters because this image keeps upstream's `CMD ["/bin/bash"]` with no `ENTRYPOINT` — a
pod that relied on a previous image's blocking entrypoint needs one line added:

```yaml
# Option A — appliance semantics, minimal diff from a pod with no `command:` today:
command: ["/usr/local/bin/emulator-entrypoint"]

# Option B — explicit control over boot timing, consistent with this project's build-agent pods:
command: ["tail", "-f", "/dev/null"]
# ...then, in the pipeline step itself:
#   sh 'emulator-tools start && emulator-tools wait-ready'
```

Option B is the recommended default: it keeps the emulator's boot firmly inside a timed pipeline stage
(so a slow or hung boot shows up as *that* stage failing, not as a pod that never becomes ready) rather
than an implicit side effect of the container starting.

KVM itself needs no special Kubernetes setup beyond what already grants it today (`privileged: true`, no
`runAsUser`) — there is no device plugin or `kvm` group involved.

## Jenkins migration

Moving an existing Maestro pipeline onto this image lets you delete three stages outright, because the
image now does what they used to do by hand:

| Today | After |
| :--- | :--- |
| `stage('Install Maestro CLI')` — unpinned `curl … \| bash`, on every build | Gone. Maestro is baked into the `-maestro` variant, version-pinned and Renovate-tracked. |
| `stage('Prepare Emulator')` — hand-rolled `adb`/boot-completed polling | `emulator-tools wait-ready` — a real poll with a timeout and a non-zero exit on failure. |
| Manual `settings put global *_animation_scale 0` calls | Image default (`EMULATOR_DISABLE_ANIMATIONS=true`). |
| `setprop persist.sys.locale` + `adb shell "stop; start"` + a **second** boot wait | `EMULATOR_LOCALE` — the emulator applies it, `wait-ready` waits for it. |
| `adb start-server` run by the pipeline | The entrypoint's job now. |

The pod spec needs exactly one added line — see [Kubernetes guidance](#kubernetes-guidance) above for
the two equivalent options. Everything else in the pipeline (the Gradle build, `maestro test`) is
unchanged.

## Baseline profiles

Baseline-profile **generation** is supported and is what this image is scoped for — Google's own
guidance is that it works without root from API 33 onward, and the matrix's API 34 image clears that bar
comfortably. The `aosp_atd` flavor of the API 34 image is the recommended target for that job: root
isn't strictly required at 34, but AOSP avoids GMS noise and keeps the job working unmodified if it ever
needs to run below API 33, where an AOSP/rootable image *is* mandatory.

> [!IMPORTANT]
> Macrobenchmark **measurement** is explicitly out of scope. Google's own documentation states it
> discourages benchmarking on an emulator because the numbers are not representative of a real device —
> and that Macrobenchmark *returns errors* when it detects one. This is not a soft warning; it errors
> out. Do not build a performance or regression gate on top of this image. Generation is device-independent
> (the output is a class/method list compiled per-device at install time), so the generation API level
> does not lock in the result — but it does not turn this into a benchmarking image either.

## Image size expectations

Be upfront about this: each tag carries a full Android system image (~1–1.5 GB) plus the emulator binary
and its libraries (~500 MB), on top of upstream's own layers. Expect **2.5–4 GB uncompressed** per tag,
versus upstream's ~340 MB compressed base. That is inherent to shipping an emulator, not a defect to
chase away. Mitigations actually taken: ATD system images by default (far smaller and faster-booting than
`google_apis`), `zstd` level 9 compression, exactly one API level per tag (never bundling several), and
cleaning up `.temp` / `.downloadIntermediates` / `.patches` / SDK caches inside the same `RUN` layer that
creates them.

## FAQ

**ATD vs. `google_apis` — which should I use?**\
`IMG_TYPE=google_atd` (or `aosp_atd`) is the intended default: Automated Test Device images boot faster
and use less RAM, and they are what Google explicitly builds for CI. But production runs `google_apis`
today, and ATD images drop the Play Store and some system surface. Treat `google_atd` as a default that
has to be **earned by validation**, not assumed safe — run your actual UI-test suite against both image
types before switching a production pipeline over, and keep `google_apis` (`SYSTEM_IMAGE_TYPE_LEGACY` in
`versions.env`) as the documented escape hatch for flows that need full GMS or Play Store.

**How does `EMULATOR_LOCALE` work?**\
The emulator has no way to boot straight into a locale: `-prop` only accepts `qemu.*` properties and
silently drops `persist.sys.locale`. `-change-locale <locale>` is the supported path. It sets the locale
after the first boot completes and then restarts the framework, every time, even when the locale is
already persisted. `sys.boot_completed` stays `1` during that restart, so polling it alone reports ready
too early. `wait-ready` therefore also waits until `persist.sys.locale` matches, `system_server` has
restarted, and user 0 is `RUNNING_UNLOCKED` again. That costs a framework restart (a few seconds), not a
second cold boot, and pipelines no longer script it themselves.

**Why is `ANDROID_EMULATOR_VERSION` pinned to `37.1.11` and not the newer-looking `37.2.5`?**\
Google publishes emulator builds across several channels (stable/beta/canary/dev). `sdkmanager` installs
from the **stable** channel by default (`--channel=0`), and `37.1.11` (build-id `15917651`) is what that
channel actually serves as of this writing — `37.2.5` (build-id `16079175`) lives in the *dev* channel.
Pinning the version our build step actually installs (and asserts against, at build time) keeps
`versions.env` truthful instead of aspirational.

## Attribution

This project derives substantially from
[G00fY2/alpaquita-android](https://github.com/G00fY2/alpaquita-android) (MIT license, © Thomas Wirth) —
the base image, its Alpaquita/`mimalloc`/GID-0 foundations, and its engineering conventions
(`AGENTS.md`) are inherited wholesale. See [`LICENSE`](LICENSE) for the full license text, which retains
the original copyright notice alongside this project's own.
