# Handover: `alpaquita-android-emulator`

> **For the agent reading this:** this is the complete specification for a **new, empty repository**.
> Nothing exists yet — you are creating the whole project from scratch. Read this file end to end
> before writing anything. The decisions in §3 are **settled** — implement them, don't relitigate them.
>
> Everything under "Verified facts" was empirically tested on 2026-08-21 — trust it over your priors,
> but re-verify version numbers, which move. **§2.7 is the most important section**: it documents the
> live cluster and pipeline this image has to slot into, including one trap (§2.7.3) that fails silently.

---

## 1. What we are building and why

An **Android CI Docker image that can both build an Android app and run a hardware-accelerated
emulator**, so a Jenkins-on-Kubernetes pipeline can compile *and* run instrumented / Maestro UI tests
in one place.

It replaces `nilsjrfn/docker-android:api-*`, produced by the now-archived
`nilsjrfn/maestro-emulator` repo. That image **works today** in our Android Jenkins pipeline
(`nilsjrfn/docker-android:api-34` is the tag in active use) — so this is an evolution of something
functioning, not a rescue of something broken. Treat the old image's runtime behaviour as the
**compatibility baseline**: whatever we ship must keep that pipeline green.

The new foundation is **[G00fY2/alpaquita-android](https://github.com/G00fY2/alpaquita-android)** (MIT,
© Thomas Wirth) — a modern, minimal, self-updating Android CI image. Its README states explicitly:

> **Not included:** Android NDK and the Android Emulator. […] dedicated NDK/Emulator variants are planned.

We are building that missing emulator variant, plus a Maestro-enabled flavour on top.

### Three goals, in priority order

1. **Correctness / compatibility** — the emulator boots headless under KVM and ADB is reachable, as it
   is today.
2. **Fitness for the real cluster** — see §2.7. KVM already works there via `privileged: true`, and the
   pod runs as root, so arbitrary-UID support is **not** a current requirement. We still inherit
   upstream's GID 0 pattern because it costs nothing, but do not contort the design for it. What *does*
   matter operationally is not breaking the pod's volume-mount convention (§2.7.3).
3. **Maestro-ready** — a `-maestro` variant so we can run Maestro flows in CI. This is not speculative:
   a Maestro pipeline already runs in production and re-downloads the CLI on every build (§2.7.4). Design
   for it from day one even if it lands in a later phase.

---

## 2. Verified facts (tested, not assumed)

These were checked by actually running containers. They de-risk the two questions that would otherwise
sink the project.

### 2.1 The Android emulator runs on Alpaquita glibc ✅

Alpaquita is Alpine-derived (`ID_LIKE=alpine`) but the **glibc** flavour is what upstream uses — which
is exactly why this works. Google's emulator binaries are built against glibc and would need `gcompat`
shims on musl/Alpine.

Confirmed inside `ghcr.io/bell-sw/liberica-runtime-container:jdk-25.0.4_9-glibc`:

```
Android emulator version 37.2.5.0 (build_id 16079175)
```

`ldd` on both `emulator` and `qemu/linux-x86_64/qemu-system-x86_64` reports **zero missing shared
libraries** with the package set below.

### 2.2 The exact apk package set required

Alpaquita's repos (`core` + `universe`) carry everything. Versions observed:

| Purpose | Packages |
| :--- | :--- |
| **Emulator hard requirements** (found by `ldd`, all three missing by default) | `libbsd` (0.12.2, pulls `libmd`), `libxi` (1.8.3), `libuuid` (2.42.2) |
| Graphics / SwiftShader | `mesa-gl` (26.1.6), `mesa-dri-gallium`, `mesa-gbm`, `libdrm` (2.4.134) |
| X11 | `libx11` (1.8.13), `libxcb` (1.17.0), `libxkbcommon` (1.13.2), `libxext`, `libxrender`, `libxcursor`, `libxshmfence` |
| Audio stubs (emulator links them even with `-no-audio`) | `libpulse` (17.0), `alsa-lib` (1.2.16.1) |
| Misc runtime | `dbus-libs` (1.16.2), `nss` (3.125), `libstdc++` (already in base) |
| Virtual framebuffer (only needed for `-gpu host`) | `xvfb` (21.1.24) |
| ADB port forwarding | `socat` (1.8.1.3) |

> ⚠️ **Gotcha:** `apk search -x libbsd` returns *nothing*, yet `apk add libbsd` installs it fine.
> Do not use `apk search` to validate this list — install and `ldd` instead.
>
> ❌ **Not available in Alpaquita:** `pulseaudio-libs` (wrong name — use `libpulse`), `x11vnc`
> (irrelevant for headless CI; drop the old image's VNC ambitions).

### 2.3 ATD system images exist and are the intended default

Google ships **Automated Test Device** images — stripped down, much faster to boot, far less RAM, built
specifically for CI. Availability confirmed from Google's own repo XML:

| Image type | API levels available |
| :--- | :--- |
| `aosp_atd` | 30–36 |
| `google_atd` | 30–36 |
| `google_apis` | 10–36 (everything) |

**Rule to implement:** default to an ATD image for API ≥ 30, fall back to `google_apis` for API 28/29.
Make it an overridable build arg, because ATD images lack some Play-services surface — if a Maestro flow
needs Play Store or GMS, `google_apis` is the escape hatch.

⚠️ Production runs `google_apis` today, so treat ATD as the *intended* default that must be **earned by
validation**, not switched on blind — see §6.3.

### 2.4 Upstream's shape (what we inherit)

- Base: `ghcr.io/bell-sw/liberica-runtime-container:jdk-{21,25,26}-glibc`, digest-pinned, selected by
  `ARG BASE_IMAGE`.
- `mimalloc` preloaded via `LD_PRELOAD` for Gradle/Kotlin speed.
- `/bin/sh` symlinked to `bash`, then validated.
- Paths: `ANDROID_HOME=/opt/android/sdk`, `ANDROID_SDK_HOME=/opt/android/user`,
  `ANDROID_USER_HOME=$ANDROID_SDK_HOME/.android`, `GRADLE_USER_HOME=$ANDROID_SDK_HOME/.gradle`.
- **GID 0 pattern:** `chgrp -R 0` + `chmod -R g=u` on both `/opt/android/sdk` and `/opt/android/user`.
- `CMD ["/bin/bash"]` — no entrypoint. The image is a build agent, not an appliance.
- `.dockerignore` is `**` + `!scripts/`; build scripts are `--mount=type=bind`ed, never `COPY`d, so they
  leave no layer.
- Tags: `android-<api>-jdk<jdk>` (rolling), `android-<api>-jdk<jdk>-v<year>.<rel>.<patch>` (immutable),
  `latest`.
- Matrix keeps only the **three newest major API levels** — 37/36/35 at time of writing.
- CI: `versions.env` + Renovate custom datasources scraping Google's `repository2-1.xml` /
  `repository2-3.xml`; two-stage release (conventional commits on `main` → tag → release build);
  Dive (layer efficiency), Trivy (CVE), a real Gradle build smoke test, and a generated manifest that
  becomes the GitHub Release body.
- Published to Docker Hub **and** GHCR, `zstd` level 9, SBOM + provenance.
- MIT licensed. `AGENTS.md` holds their engineering standards — **read it, it is our style guide too.**

### 2.5 There is no API 37 system image — the emulator matrix caps at 36 ✅

This is the single most important constraint on the matrix, and it is easy to get wrong because the SDK
*platform* and the *system image* are versioned independently.

Checked against every `sys-img` channel (`sys-img2-1/2-2/2-3.xml`) for every image type:

| Artifact | Highest available |
| :--- | :--- |
| SDK platforms (`repository2-3.xml`) | **37.2** (37.0, 37.1, 37.2 all published) |
| System images — `android`/`default` | **36** |
| System images — `google_apis` | **36** |
| System images — `google_apis_playstore` | **36** |
| System images — `aosp_atd` / `google_atd` | **36** (from 30) |

**You cannot boot an API 37 emulator today.** Google has shipped the platform to compile against but no
system image to run on. So "latest is 37" is true for `compileSdk` and irrelevant for us: our ceiling is
**API 36**. Have CI assert this rather than assume it — when Google publishes API 37 images the
`emulator-version-fetcher` action should surface it.

### 2.6 The new `android` CLI: real, useful, and a hermeticity hazard ⚠️

`cmdline-tools;23.0` (build id `16111833`) ships a new unified `android` CLI next to the legacy tools.
Full `bin/` contents:

```
android  apkanalyzer  avdmanager  d8  lint  profgen
r8  resourceshrinker  retrace  screenshot2  sdkmanager
```

`android --version` → **`1.0.15985488`**. Relevant subcommands:

```
android sdk       install | update | remove | list        # replaces sdkmanager
android emulator  create | start | stop | list | remove   # replaces avdmanager + launcher
android install | run | layout | screen | describe | docs | skills | studio
```

Two findings that matter more than the feature list:

1. **`android emulator start` "will return when the emulator is fully started and ready to use."**
   That is exactly the `wait_for_boot` logic the old repo hand-rolled (and got wrong — defect #5). Using
   it would delete a whole class of polling bugs.

2. **The `android` binary in cmdline-tools is only a bootstrapper.** First invocation prints
   `Downloading Android CLI...` and unpacks **235 MB** into `$ANDROID_USER_HOME`. Verified: it honours
   `ANDROID_USER_HOME` (it wrote to `/opt/android/user/.android/{bin,cli}` when set, and only put a
   `.cache` dir in `$HOME`). It also has a self-updating `android update` subcommand, and **collects
   usage metrics by default** — which is precisely what upstream's `android-tools disable-metrics`
   / `~/.androidrc` `--no-metrics` exists to suppress.

   Consequences for us:
   - **Pre-warm it at build time.** Upstream's `ANDROID_USER_HOME=/opt/android/user/.android` under GID 0
     is already the right home, so one `android --no-metrics --version` in the build layer bakes the
     235 MB in, shared by every UID. Skip this and **every CI job re-downloads 235 MB.**
   - **Never let it self-update at runtime** — that breaks reproducibility. Pin, and don't call
     `android update`.
   - Pass `--no-metrics` (or run `android-tools disable-metrics`) everywhere.

`profgen` in that same `bin/` is the baseline-profile compiler — noted because of §3.4.

### 2.7 The actual production environment (read this before designing anything)

Pulled from `fn-mz/mobile-app-android` on `develop`. This is not hypothetical — it is what runs today,
and it answers several questions the earlier draft left open.

#### 2.7.1 Pod specs — KVM is already solved

`.jenkins/pods/emulator.yaml`:

```yaml
containers:
  - name: emulator-34
    image: docker-cache.prod.fnmz.org/nilsjrfn/docker-android:api-34
    securityContext:
      privileged: true            # <- this is what grants /dev/kvm today
    resources:
      requests: { memory: "16Gi", cpu: "8.0" }
      limits:   { memory: "32Gi", cpu: "12.0" }
    imagePullPolicy: Always
    env:
      - name: GRADLE_OPTS         # gradle runs in THIS container
        value: >- … -Xmx6g …
    tty: true
    # NOTE: no `command:` — the container stays alive because the image's
    #       ENTRYPOINT (/opt/start-emulator.sh) blocks running the emulator.
```

**Phase 0 is therefore already answered: KVM works, via full `privileged: true`.** No device plugin, no
`kvm` group. Also note there is **no `runAsUser`** — it runs as root. (Narrowing `privileged: true` to a
`/dev/kvm` device mount would be a nice hardening follow-up, but it is out of scope here.)

Sizing: 8–12 CPU and 16–32 Gi, with Gradle taking `-Xmx6g`. There is plenty of headroom — the old AVD's
`hw.ramSize=2048` is needlessly small. Target **4096–6144 MB** and 4–6 cores for the AVD.

#### 2.7.2 Upstream is already in production here

`.jenkins/pods/android.yaml` builds with:

```
docker-cache.prod.fnmz.org/g00fy2/alpaquita-android:android-37.1-jdk26-v2026.7.0
command: [ "tail", "-f", "/dev/null" ]
```

So the foundation is **proven in this cluster**, on an immutable pinned tag, JDK 26 / Android 37.1. Note
the pairing that validates §2.5 perfectly: they *compile* against platform 37.1 and will *run tests* on
API ≤ 36, because no API 37 system image exists.

Note also the two container-lifecycle idioms in use: the build pod uses `command: tail -f /dev/null`
(build agent), the emulator pod uses **no** `command` and relies on the blocking image entrypoint
(appliance). That is precisely the §3.2 distinction, confirmed in the wild.

#### 2.7.3 ⚠️ The volume-mount trap that would break a naive port

`android.yaml` mounts an `emptyDir` **over `/opt/android/user`**:

```yaml
volumeMounts:
  - { mountPath: /opt/android/user, name: fast-shared-volume, subPath: android-user }
```

That path is upstream's `ANDROID_SDK_HOME`, containing `ANDROID_USER_HOME=/opt/android/user/.android`.
If the emulator pod copies this convention, the mount **masks everything we baked there** — namely the
pre-created AVD *and* the 235 MB pre-warmed `android` CLI (§2.6). Result: no AVD at runtime, and a
235 MB re-download per build. Silent, and confusing to debug.

**Mitigation (do this):** put the AVD outside the mounted subtree via
**`ANDROID_AVD_HOME=/opt/android/avd`** — a GID-0'd sibling of `/opt/android/user`. And in the emulator
pod, if a cache volume is wanted, mount the narrower `/opt/android/user/.gradle` rather than the whole
user dir. Document both in the README.

#### 2.7.4 The Maestro pipeline that exists today

`.jenkins/maestro-tests.groovy` runs with `defaultContainer 'emulator-34'` — Gradle build, `adb`, and
Maestro all execute inside the emulator container. Confirms the one-container-does-both design of §3.2.

Three of its stages are pure workarounds for gaps in the current image, and the new image should delete
them outright:

1. **`stage('Install Maestro CLI')`** — `curl -Ls "https://get.maestro.mobile.dev" | bash` on *every
   build*: an unpinned version plus a network dependency in the hot path. The `-maestro` variant removes
   this stage entirely. Bake `MAESTRO_CLI_NO_ANALYTICS=1` in too (the pipeline already sets it).
2. **`stage('Prepare Emulator')`** — a hand-rolled `adb start-server` / `adb wait-for-device` /
   `until getprop sys.boot_completed` loop, with the telling comment *"Unlike the connected\* gradle
   tasks, maestro does not wait for a device itself."* This is exactly `emulator-tools wait-ready`.
   It also manually sets the three animation scales to 0 — because the old image's `DISABLE_ANIMATION`
   defaulted to off and so never ran (see §5.2). **Default animations off in the new image.**
3. **The locale dance** — `setprop persist.sys.locale de-DE`, then `adb shell "stop; start"`, then wait
   for `boot_completed` *a second time*. That is a full framework restart per build inside a 10-minute
   stage budget. Instead, pass locale as a launch property (`emulator -prop persist.sys.locale=de-DE …`)
   or bake it into the AVD, so the device boots in the right locale **once**. Expose it as
   `EMULATOR_LOCALE`, defaulting to unset. This is likely the single biggest wall-clock win available.

Other facts worth carrying:

- `adb start-server` is run *by the pipeline* — direct evidence that defect #1 (build-time adb/socat)
  bites in practice. Since the emulator and the client share one container, **`socat` forwarding is not
  needed for this pattern**; make it opt-in, for the sidecar case only.
- The JSON state protocol (`ANDROID_READY` / `state-update`) is **not consumed anywhere** in that repo.
  Keep it as human-readable log output, but it is *not* a contract to preserve.
- Current suite is one flow (`.maestro/flows/common/navigation.yaml`) with a TODO to enable the full
  tagged suite; timeouts are 10 min prepare / 45 min tests / 90 min total.
- The app is `com.fressnapf.app.dev.debug` built as `assembleGoogleDevDebug`, and the flows assert German
  strings — hence the locale requirement.

---

## 3. Decisions (settled)

### 3.1 DECIDED — build `FROM` upstream's published image

Do **not** fork. Use `FROM g00fy2/alpaquita-android:<immutable-tag>@sha256:<digest>` and add the emulator
on top. Pin tag **and** digest per upstream's own standard, and let Renovate bump it.

Start from the tag already proven in this cluster (§2.7.2): **`android-37.1-jdk26-v2026.7.0`**. Matching
the build pod's base keeps one JDK/SDK story across both pods.

Remember why the API-level objection doesn't apply: the emulator's **system-image** API level is
independent of the SDK **platform** API level. An API-34 emulator needs `system-images;android-34;…`, not
`platforms;android-34`. Upstream's narrow platform matrix therefore does not constrain our emulator
matrix at all.

### 3.2 DECIDED — build agent by default, appliance on demand

Keep upstream's `CMD ["/bin/bash"]`. Ship an `emulator-tools` CLI mirroring upstream's `android-tools`:

```bash
emulator-tools start          # launch emulator in background, return immediately
emulator-tools wait-ready     # block until booted; non-zero exit on timeout
emulator-tools stop
emulator-tools status
```

so one container can do `emulator-tools start && ./gradlew … && maestro test …`. Also ship
`/usr/local/bin/emulator-entrypoint` so appliance mode stays available via `docker run --entrypoint`, and
document the k8s **sidecar** pattern (emulator in its own pod container, ADB over the pod network) in the
README — that is where the appliance entrypoint genuinely earns its place.

Implementation notes:

- `wait-ready` is the **public contract**. Implement it over `adb`/`getprop sys.boot_completed` with a
  real timeout and non-zero exit, and keep emitting the old repo's JSON state protocol
  (`{ "type": "state-update", "value": "ANDROID_READY" }`) — the Jenkins pipeline may parse it.
- You *may* implement `start` on top of `android emulator start` (§2.6), which already blocks until
  ready. Do it behind our own CLI so the contract stays ours, keep the JSON output, and keep the
  `adb`-based fallback — the CLI is v1.0 and self-updating, so don't make it load-bearing yet.
- The JSON state protocol is **not** parsed by the pipeline (§2.7.4), so it is log output, not a contract.
  Keep it anyway — it is cheap and readable.
- ⚠️ **Breaking change, but the migration is one line.** `emulator.yaml` currently has no `command:` and
  depends on the blocking entrypoint (§2.7.1). With `CMD ["/bin/bash"]` the container would neither stay
  alive nor start the emulator. Fix it in the pod spec, in the same change:

  ```yaml
  # option A — keep appliance semantics, minimal diff:
  command: [ "/usr/local/bin/emulator-entrypoint" ]

  # option B — match android.yaml's idiom, start explicitly in the Jenkinsfile:
  command: [ "tail", "-f", "/dev/null" ]   # then: sh 'emulator-tools start && emulator-tools wait-ready'
  ```

  Because the pod spec can set `command`, **no separate `-appliance` tag is needed.** Prefer option B for
  consistency with `android.yaml` and for explicit control over boot timing.

### 3.3 DECIDED — the matrix

**API level × variant**, capped at 36 (§2.5). JDK stays single-valued (upstream's latest): emulator
behaviour is JDK-independent and Maestro just needs *a* JVM.

| API | Why | Image type |
| :--- | :--- | :--- |
| **36** | Highest bootable. Catches new-platform behaviour changes before they hit users; the level to move `targetSdk` onto. | `google_atd` |
| **34** | Continuity — `api-34` is what production uses today. Large real-world install base. Also the baseline-profile level (§3.4). | `google_atd`, plus an `aosp_atd` flavour for baseline profiles |
| **30** *(optional)* | Cheapest meaningful old-behaviour regression guard; first ATD level. Add only if something concretely needs it. | `aosp_atd` |

Recommendation: **start with 36 and 34.** That is 2 API levels × 2 variants = **4 images**, down from the
old repo's 8, while covering more relevant ground. Add 30 later if a real regression justifies it.

Drop API 28 unless something concretely requires it: it predates ATD, forcing slow `google_apis` boots.

`IMG_TYPE` stays a build arg. Default `google_atd` for API ≥ 30 (ATD = far faster boots, less RAM, built
for CI), with `google_apis` as the escape hatch when a flow needs full GMS or Play Store, and `aosp_atd`
for the baseline-profile job.

Tags:

```
android-<api>-emulator                     # rolling
android-<api>-emulator-maestro
android-<api>-emulator-v<year>.<rel>.<pat> # immutable — use THESE in Jenkins
android-<api>-emulator-maestro-v<…>
latest                                     # highest API (36), emulator variant
```

**Registry (confirmed):** Docker Hub namespace **`nilsjrfn`**; GHCR is **not** used. The cluster pulls
through the mirror `docker-cache.prod.fnmz.org/<dockerhub-path>` (§2.7.1), so the image must live under
`nilsjrfn/` for the existing prefix to resolve. Recommended name:
**`nilsjrfn/alpaquita-android-emulator`**.

Publishing to GHCR as well is optional and free; skip it unless someone wants it — Docker Hub is the only
path that matters here. Also switch the emulator pod to **immutable** tags (`android.yaml` already pins
`…-v2026.7.0`, while `emulator.yaml` still rides the rolling `api-34`).

### 3.4 Baseline profiles: API 34 is fine — newest is neither required nor possible

Per Google's own requirements:

> "When using Jetpack Macrobenchmark 1.2.0-alpha06 and higher, you can generate the Baseline Profile on
> devices running Android 13 (API 33) and higher **without root access**."

> "If you use a Gradle Managed Device, set `aosp` as the `systemImageSource`, because you need root
> access for the Baseline Profile generator."

So:

- **API 34 clears the bar.** The threshold that matters is **33** (the no-root line). Generating on 34 is
  fully supported; there is no benefit in chasing the newest API for its own sake, and API 37 is
  impossible anyway (§2.5).
- **Use an AOSP-flavoured image** for the baseline-profile job (`aosp_atd` at API 34). Root isn't needed
  at 34, but AOSP avoids GMS noise and keeps the job working if it ever runs below 33. Below API 33 an
  AOSP/rootable image is mandatory, not optional.
- The generated profile is a device-independent list of classes/methods, compiled per-device at install
  time (that's what `profgen` in §2.6 is for), so the generation API level does not lock the output. Pick
  a level that exercises representative code paths — if the app has API-gated branches, generating on the
  newest bootable level (36) is a reasonable second job, not a replacement for 34.

⚠️ **Critical distinction — do not plan on perf numbers from this image.** Baseline profile *generation*
on an emulator is supported and is what Google recommends via Gradle Managed Devices. Macrobenchmark
*measurement* is not:

> "We discourage running the benchmarks on an emulator, as they don't produce performance numbers
> representative of the end-user experience."
>
> "Macrobenchmark also returns errors when attempting to measure an emulator."

It **errors out**, it doesn't merely warn. Timing/regression benchmarking needs physical devices — a
separate concern from this image. Scope this project to profile *generation* only, and say so in the
README so nobody wires a perf gate onto it.

### 3.5 DECIDED — provisioning uses `sdkmanager`/`avdmanager`, not the new CLI

For **build-time** provisioning (installing the emulator + system image, creating the AVD), use the
legacy `sdkmanager` / `avdmanager`. They are deterministic, version-pinnable, offline-friendly and add no
bootstrap. The new `android` CLI is genuinely nicer ergonomically, but at v1.0 with a 235 MB
self-download and a self-update path it is the wrong thing to make our reproducible build depend on.

Do still **pre-warm** the CLI in the build layer (§2.6) so it is available to pipelines at runtime
without a 235 MB surprise, and so `emulator-tools` can optionally delegate to `android emulator start`.

### 3.6 What the new image lets the pipeline delete

Worth stating as acceptance criteria, because it is the concrete payoff (all from §2.7.4):

| Today in `maestro-tests.groovy` | After |
| :--- | :--- |
| `stage('Install Maestro CLI')` — unpinned `curl … \| bash` every build | gone; Maestro baked into the `-maestro` variant, version pinned + Renovate-tracked |
| `stage('Prepare Emulator')` — hand-rolled adb/boot polling | `emulator-tools wait-ready` |
| manual `settings put global *_animation_scale 0` | image default |
| `setprop persist.sys.locale` + `stop; start` + second boot wait | `EMULATOR_LOCALE` as a launch property — **one** boot |
| `adb start-server` | entrypoint's job |

## 4. Target project structure

Mirror upstream's conventions closely — it makes their improvements easy to copy and their `AGENTS.md`
directly applicable.

```
alpaquita-android-emulator/
├── AGENTS.md                    # start from upstream's, extend with emulator/Maestro rules
├── CLAUDE.md                    # one line: "See AGENTS.md"
├── README.md                    # matrix, usage, KVM requirements, k8s guidance, FAQ
├── LICENSE                      # MIT — keep upstream's copyright line, add ours
├── .editorconfig .gitattributes .gitignore
├── .dockerignore                # "**" + "!scripts/" + "!avd/"
├── versions.env                 # single source of truth for every pinned version
├── Dockerfile                   # multi-stage: emulator → maestro, selected by ARG VARIANT
├── avd/
│   └── config.ini.template      # PARAMETERIZED AVD config (see §5.3)
│                                # NOTE: AVD lives at ANDROID_AVD_HOME=/opt/android/avd,
│                                #       deliberately OUTSIDE /opt/android/user (§2.7.3)
├── scripts/
│   ├── setup-emulator.sh        # BUILD: sdkmanager emulator + system-image, avdmanager create avd,
│   │                            #        then PRE-WARM the `android` CLI (§2.6)
│   ├── setup-maestro.sh         # BUILD: install Maestro CLI (maestro stage only)
│   ├── emulator-entrypoint.sh   # RUNTIME: appliance mode (PID 1, exec form)
│   ├── emulator-lib.sh          # shared: state logging, wait_for_boot, tweaks
│   ├── emulator-tools           # RUNTIME CLI: start|stop|wait-ready|status|disable-animations
│   └── healthcheck.sh           # HEALTHCHECK: boot_completed probe
└── .github/
    ├── renovate.json5
    ├── trivy.yaml  .dive-ci.yaml  .trivyignore.yaml  .yamllint.yaml
    ├── workflows/{default.yaml, lint.yaml, pr-lint.yaml}
    └── actions/
        ├── emulator-boot-smoke-test/    # NEW  — boots the emulator under KVM in CI
        ├── maestro-smoke-test/          # NEW  — runs a real Maestro flow
        ├── emulator-version-fetcher/    # NEW  — resolve emulator build-id from Google's XML
        ├── generate-manifest/           # ADAPT — add emulator/system-image/Maestro rows
        ├── generate-version/            # COPY from upstream
        ├── dive-analyze/                # COPY
        ├── merge-build-manifests/       # COPY
        └── renovate-config-validator/   # COPY
```

`versions.env` should hold, at minimum:

```
BASE_IMAGE_TAG=…                  # immutable upstream tag
BASE_IMAGE_DIGEST=sha256:…
ANDROID_EMULATOR_VERSION=…        # e.g. 37.2.5 -> build-id resolved in CI
SYSTEM_IMAGE_TYPE_DEFAULT=google_atd
SYSTEM_IMAGE_TYPE_LEGACY=google_apis
EMULATOR_RAM_MB=4096              # 2048 in the old image was needlessly small (§2.7.1)
EMULATOR_CORES=4
MAESTRO_VERSION=…                 # track latest; 1.36.0 in the old repo is long obsolete
ANDROID_CMDLINE_TOOLS_VERSION=…   # 23.0 ships the new `android` CLI; pin it (§2.6)
```

Note that upstream already installs cmdline-tools, so if §3.1's `FROM` is used, the CLI comes with the
base image — pin the base digest and pre-warm rather than reinstalling.

---

## 5. What to carry over from the old repo — and the bugs to fix

The old repo is four shell scripts, two near-identical Dockerfiles and an INI file. The *logic* is worth
keeping; the *plumbing* has real defects. **Port the intent, not the code.**

### 5.1 Keep this logic

From `start-emulator.sh` — the emulator invocation is sound and battle-tested:

```
emulator -avd "$AVD_ID" -gpu "$GPU_MODE" -cores N \
  -skip-adb-auth -no-audio -no-boot-anim -no-window -no-snapshot-save -wipe-data
```

- GPU mode selection: `swiftshader_indirect` by default; `-gpu host` + `Xvfb :0.0` when
  `GPU_ACCELERATED=true`.
- From `emulator-monitoring.sh`: the JSON state protocol
  (`{ "type": "state-update", "value": "ANDROID_READY" }`). Verified **not** parsed by the pipeline
  (§2.7.4) — keep it as readable log output, not as a contract. Plus the two settings tweaks, which
  matter a lot for UI-test stability:
  - disable animations (`window_animation_scale`, `transition_animation_scale`, `animator_duration_scale` → 0)
    — **default these ON**; the pipeline currently does it by hand because the old image's
    `DISABLE_ANIMATION` defaulted to off and never fired.
  - hidden API policy (`hidden_api_policy*` → 1)
- Build-time AVD creation via `avdmanager create avd` so containers boot without a create step.
- ADB reachable on **5555**, emulator console on **5554**. The `socat` forwarding is only needed when the
  ADB client lives in a *different* container (sidecar); in the current same-container setup it is
  unnecessary, so make it **opt-in** (`ADB_EXPOSE=true`).

### 5.2 Fix these — all real defects found in the old repo

| # | Defect | Fix |
| :-- | :--- | :--- |
| 1 | `create-emulator.sh` starts the **adb server and both `socat` forwarders at build time** (`RUN`). They live in a build layer and are gone at runtime. | Move all of it into the runtime entrypoint, where it belongs. |
| 2 | `ANDROID_AVD_HOME=/data`, but the Dockerfile copies the config to `/.android/avd/${AVD_ID}.avd/config.ini` — **two unrelated paths**, so the tuned config likely never applied. | One path — and per §2.7.3 it must sit **outside** the mount-prone user dir: `ANDROID_AVD_HOME=/opt/android/avd`. |
| 3 | `EmulatorConfig.ini` hardcodes `image.sysdir.1=system-images/android-29/google_apis/x86_64/` — **wrong for every API level except 29**, despite `API_LEVEL` being a build arg. Same for `abi.type`/`hw.cpu.arch`. | Template it (§5.3). |
| 4 | `start-emulator.sh` reads `MEMORY` and `PARTITION_SIZE` and **never passes them to the emulator** — no `-memory` / `-partition-size` flags. Dead knobs that look live. | Pass them through, or delete them. Do not ship fake configuration. |
| 5 | `wait_for_boot`'s `while [ -n "$(adb wait-for-device > /dev/null)" ]` — stdout is discarded, so the condition is always empty and the body never executes. | Rewrite as a real poll with a **timeout and non-zero exit** on failure. `android emulator start` already blocks until ready (§2.6) and can back this, but keep the `adb` path as the contract. |
| 6 | `-wipe-data` on every boot throws away the baked data partition → slow cold boot every run. | Keep `-wipe-data` off by default; consider a build-time pre-boot + snapshot to cut minutes off CI. Measure before committing to it. |
| 7 | Two ~95%-identical Dockerfiles (`android-emulator` / `android-emulator-maestro`); every edit had to be mirrored. | One Dockerfile, stages selected by `ARG VARIANT`. |
| 8 | Runs as **root** from `/root/.android` and `/data`. | Adopt upstream's GID 0 pattern; verify with `--user 1000:0` **and** a random UID. |
| 9 | A **private ADB key** (`keys/adbkey`) baked into a public image. | Do not carry it over. `-skip-adb-auth` is the default; generate a key at runtime if auth is ever needed. |
| 10 | Dead file `avd/Pixel2.avd/config.ini` — arm64, and references `/Users/ndruyen/Library/Android/sdk/skins/pixel_4`. | Drop. |
| 11 | README documented `android-base.Dockerfile` / `android-sdk.Dockerfile`, which never existed. | Keep the README honest; the manifest generator helps. |
| 12 | Local build scripts tagged `nilsjrfn/android-emulator-34` while CI published `nilsjrfn/docker-android:api-34` — two naming schemes, one of them a lie. | Single tag scheme (§3.3), CI-generated. |
| 13 | No `HEALTHCHECK`. | Add one — k8s and Jenkins both need a readiness signal. |
| 14 | `MAESTRO_VERSION=1.36.0` pinned by hand and never updated. | Track via Renovate `github-releases` on `mobile-dev-inc/maestro`. |
| 15 | `DISABLE_ANIMATION` / `DISABLE_HIDDEN_POLICY` default to unset, so the tweaks **never ran** — the pipeline re-does them by hand (§2.7.4). | Default both **on**; allow opt-out. |
| 16 | No locale support, forcing the pipeline into a `setprop` + `stop; start` + re-boot-wait cycle every build. | `EMULATOR_LOCALE` passed as an emulator launch property so the device boots correct **once**. |

### 5.3 The AVD config must be templated

The old `EmulatorConfig.ini` was a good idea — a tuned, minimal AVD (sensors off, audio off, small
screen) — implemented wrongly. Rewrite as `avd/config.ini.template` with placeholders substituted at
build time (`envsubst` or `sed`), driven by build args:

```ini
image.sysdir.1=system-images/android-${API_LEVEL}/${IMG_TYPE}/${ARCHITECTURE}/
abi.type=${ARCHITECTURE}
hw.cpu.arch=${ARCHITECTURE}
tag.id=${IMG_TYPE}
hw.ramSize=${RAM_SIZE}
disk.dataPartition.size=${DATA_PARTITION_SIZE}
# keep from the old file — all correct and valuable for CI:
PlayStore.enabled=false
hw.audioInput=no
hw.audioOutput=no
hw.accelerometer=no
hw.gyroscope=no
hw.sensors.*=no
hw.keyboard=no
```

Two judgement calls to revisit rather than copy blindly:

- **Screen size.** The old config used `320x480` at density `120`. Wonderfully fast, but Maestro
  matches on visible UI — a tiny viewport can hide elements and cause flaky, hard-to-debug failures.
  Recommend a realistic phone profile (e.g. `1080x2280` @ 440, the Pixel-class profile the dead
  `avd/Pixel2.avd` file was reaching for) and make it overridable.
- **RAM.** `2048` in the INI. ATD images are frugal, but Maestro plus a real app wants more. Start at
  `4096`, make it a build arg, and let the smoke test tell you.

---

## 6. CI/CD design

Copy upstream's `default.yaml` skeleton — matrix → build → validate → conditional push, with the
two-stage conventional-commit release — and change these things:

### 6.1 KVM in GitHub Actions (this is what makes real verification possible)

`ubuntu-24.04` x86 runners **do** expose `/dev/kvm`, so CI can genuinely boot the emulator rather than
just checking that a binary exists. Access needs the standard udev grant:

```yaml
- name: Enable KVM for all users
  run: |
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
      | sudo tee /etc/udev/rules.d/99-kvm4all.rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
```

Then `docker run --device /dev/kvm …`. Add `emulator -accel-check` as a **preflight in the entrypoint**
so a missing/inaccessible `/dev/kvm` fails immediately with an actionable message instead of hanging for
ten minutes.

### 6.2 New composite actions

- **`emulator-boot-smoke-test`** — the critical gate. Run the container with `--device /dev/kvm`, start
  the emulator, wait for `sys.boot_completed=1` with a timeout, assert `adb devices` shows the device,
  assert `adb shell getprop ro.build.version.sdk` equals the matrix API level, dump logcat on failure.
  Run it **twice: once as root (what production actually does, §2.7.1), once as a random high UID** —
  the latter is future-proofing for a possible non-privileged/non-root cluster, not a release gate. If it
  fails, note it and move on rather than blocking Phase 3.
- **`maestro-smoke-test`** (maestro variant only) — boot, then run a trivial flow against a
  system app (e.g. launch Settings, assert visible text). Proves Maestro can see the emulator via ADB —
  the integration that actually breaks in practice. Mirror the real pipeline's shape (`--format junit
  --output …`, `MAESTRO_CLI_NO_ANALYTICS=1`) so CI exercises the same code path as production.
- **Locale assertion** — if `EMULATOR_LOCALE` is set, assert `getprop persist.sys.locale` matches
  **without** a framework restart. That is the §2.7.4 win; regressing it silently would be easy.
- **`emulator-version-fetcher`** — resolve the emulator build-id from
  `https://dl.google.com/android/repository/repository2-3.xml` (the zips are
  `emulator-linux_x64-<build-id>.zip`), the same trick upstream uses for cmdline-tools.

### 6.3 Adapt

- **`generate-manifest`** — add rows for emulator version, system image type/API, AVD profile, and
  Maestro version. Keep the `sdkmanager --list_installed` + `apk info -v` tables.
- **`.dive-ci.yaml`** — upstream demands ≥99% efficiency and ≤1 MB wasted. Our images are **several GB**
  (a system image alone is ~1–1.5 GB). The *ratio* rules should still hold, but expect to relax
  `highestWastedBytes`. **Relax it deliberately, with a comment explaining why** — don't silently
  delete the gate.
- **Renovate** — copy their custom datasources verbatim, then add: the upstream base image
  (digest-pinned), Maestro (`github-releases`), and the emulator version. Keep `:automergeAll` — it only
  works because the smoke tests are real, which is the whole point of §6.2.
- **Matrix** — replace their JDK × platform grid with **API level × variant** per §3.3 (36 and 34, two
  variants each), and point `latest` at API 36 + `emulator`.
- **Assert the ceiling** — have CI fail loudly if a requested API level has no published system image,
  rather than producing a broken tag (§2.5).
- **Validate the `google_apis` → `google_atd` switch, don't assume it.** Production runs `google_apis`
  today. `google_atd` keeps a GMS subset (so Firebase-style dependencies should be fine) but drops the
  Play Store and some system apps. The app under test is a real commercial app; run its actual
  `navigation.yaml` flow on both image types before making ATD the default, and keep `google_apis` as the
  documented fallback.

### 6.4 Size and time budget

Be honest about this up front: each image carries a system image (~1–1.5 GB) plus the emulator
(~500 MB), so expect **2.5–4 GB uncompressed** per tag, versus upstream's ~340 MB compressed. That is
inherent, not a defect. Mitigations worth taking: ATD images (§2.3), `zstd -9` like upstream, one API
level per tag (never bundle several), and aggressive cleanup of `.temp` / `.downloadIntermediates` /
`.patches` inside the same `RUN` layer.

---

## 7. Risks

| Risk | Severity | Mitigation |
| :--- | :--- | :--- |
| ~~`/dev/kvm` availability~~ | **Resolved** | Confirmed working via `privileged: true` in `emulator.yaml` (§2.7.1). No further action. |
| **Volume mount masking the baked AVD and pre-warmed CLI** (§2.7.3) — silent, and looks like a broken image | **High** | `ANDROID_AVD_HOME=/opt/android/avd`, outside `/opt/android/user`. Assert in the boot smoke test that the AVD is found and no `Downloading Android CLI...` appears. |
| Breaking the working Jenkins pipeline via the entrypoint change (§3.2) | Medium | One-line `command:` addition to `emulator.yaml`, landed in the same change. |
| `google_atd` missing a GMS/Play surface the app needs | Medium | Validate with the real `navigation.yaml` flow before defaulting; `google_apis` fallback (§6.3). |
| Image size straining registry/pull times | Medium | ATD, zstd, per-API tags. Measure pull time on a real agent. |
| Maestro 2.x differs substantially from the pinned 1.36.0 | Medium | Adopt current Maestro; don't port old assumptions. Verify its ADB discovery inside the container early. |
| **`android` CLI re-downloading 235 MB per job** because the pre-warm was skipped or `ANDROID_USER_HOME` drifted | Medium | Pre-warm in the build layer; assert in the boot smoke test that no `Downloading Android CLI...` appears in container output. |
| `android` CLI self-updating at runtime, breaking reproducibility | Medium | Never call `android update`; pin cmdline-tools; treat the CLI as optional, not load-bearing (§3.5). |
| Someone wires a **perf gate** onto emulator macrobenchmarks | Medium | Macrobenchmark *errors out* on emulators (§3.4). Say so in the README; scope to profile generation only. |
| Upstream drops an API level we depend on | Low (see §3.1) | Emulator API level is independent of platform API level; escape hatch is Option B. |
| ATD images missing GMS surface a flow needs | Low | `IMG_TYPE` build arg → `google_apis`. |
| Alpaquita package renames breaking the build | Low | Renovate + the boot smoke test catch it. |

---

## 8. Suggested phasing

Each phase ends green and useful on its own. Don't start the next until the acceptance criteria pass.

**Phase 0 — Done.** KVM is confirmed working via `privileged: true` (§2.7.1), the registry and namespace
are settled (§3.3), and all §3 decisions are made. Nothing blocks Phase 1.

**Phase 1 — Repo scaffolding.** Structure from §4, `AGENTS.md` derived from upstream, MIT `LICENSE`
retaining Thomas Wirth's copyright, `.editorconfig`, `versions.env`, lint workflows
(shellcheck/shfmt/hadolint/yamllint/actionlint). *Acceptance: lint CI green on an empty-ish repo.*

**Phase 2 — Emulator image, local only.** `Dockerfile` + `setup-emulator.sh` + templated AVD +
entrypoint/`emulator-tools` + the `android` CLI pre-warm (§2.6). *Acceptance: locally, on an x86_64 host with KVM, the container boots to
`ANDROID_READY`, `adb connect localhost:5555` works, and `adb shell getprop sys.boot_completed` is `1`.*

**Phase 3 — CI: build, validate, verify.** Port the workflow, add `emulator-boot-smoke-test` with the
udev KVM grant, wire Dive/Trivy/manifest. *Acceptance: PR builds boot a real emulator in GitHub Actions
and pass under both `1000:0` and a random UID.*

**Phase 4 — Publish.** Docker Hub (`nilsjrfn/alpaquita-android-emulator`; GHCR optional, §3.3), tag
scheme, versioning, GitHub Release with the merged
manifest, Renovate with automerge. *Acceptance: a tag produces published, pinnable images and a release
whose manifest correctly lists emulator + system image versions.*

**Phase 5 — Maestro variant.** `setup-maestro.sh`, the `maestro` stage, `maestro-smoke-test`, Renovate
tracking. *Acceptance: `maestro test` runs a real flow against the booted emulator in CI.*

**Phase 6 — Migrate Jenkins** (in `fn-mz/mobile-app-android`). In one change: point `emulator.yaml` at
`nilsjrfn/alpaquita-android-emulator:android-34-emulator-maestro-v<…>`, add the `command:` line (§3.2),
and delete the three now-redundant stages from `maestro-tests.groovy` (§3.6). Keep the narrow-mount rule
from §2.7.3 in mind if a cache volume is added.
*Acceptance: the Maestro pipeline is green, and measurably faster — the removed Maestro download, the
removed hand-rolled boot poll, and the eliminated locale framework-restart should all show up in the
`Prepare Emulator` and total wall-clock numbers versus `nilsjrfn/docker-android:api-34`.*

---

## 9. Reference

- Upstream: <https://github.com/G00fY2/alpaquita-android> — read its `AGENTS.md` and `README.md` first.
- Old repo (archived, local): `/Users/nils.druyen/Development/private/maestro-emulator` — for the
  emulator flags, the JSON state protocol and the settings tweaks. Its `CLAUDE.md` documents the
  build-time/run-time split and the config-precedence traps in more detail.
- Google SDK repo XMLs: `repository2-1.xml` (cmdline/platform/build-tools),
  `repository2-3.xml` (platforms, emulator), `sys-img/<type>/sys-img2-3.xml` (system images).
- Alpaquita: <https://bell-sw.com/alpaquita-linux/> · Liberica: <https://bell-sw.com/libericajdk/>
- Maestro: <https://docs.maestro.dev/> · releases on `mobile-dev-inc/maestro`.
- Currently in production and the compatibility baseline: `nilsjrfn/docker-android:api-34`.
- Consumer repo (pod specs + the Maestro pipeline to migrate): `fn-mz/mobile-app-android`, branch
  `develop` — `.jenkins/pods/{emulator,android,lightweight}.yaml`, `.jenkins/maestro-tests.groovy`,
  `.maestro/`.
- Registry mirror in the cluster: `docker-cache.prod.fnmz.org/<dockerhub-path>`.

**Attribution:** this project derives substantially from G00fY2/alpaquita-android (MIT, © Thomas Wirth).
Keep the upstream copyright in `LICENSE` and credit the origin in the README.
