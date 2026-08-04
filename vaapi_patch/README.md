# GStreamer VAAPI decoder for flutter_webrtc (libwebrtc m144)

This patch gives your Flutter Linux app **VAAPI hardware H.264 decoding** with
automatic fallback to the FFmpeg software decoder — the "switch" you asked for.

```
OPENNOW_DECODER=software  → forces software decode (FFmpeg)
(unset / anything else)   → VAAPI first, FFmpeg fallback
```

Your stats overlay should then read `GStreamerVaapiH264` instead of
`FFmpegVideoDecoder` when VAAPI is active.

## Files

| File | What it is |
|---|---|
| `vaapi_h264_bitstream.h` | AVCC→Annex-B converter + SPS/PPS re-injection (dependency-free, unit-tested) |
| `vaapi_video_decoder.h` | `CreateVaapiVideoDecoderFactory()` declaration |
| `vaapi_video_decoder.cc` | GStreamer decoder + factory (appsrc→h264parse→vah264dec/vaapih264dec→videoconvert→I420→appsink) |
| `patch_build_gn.py` | Anchored patch: adds gstreamer pkg_config + sources to wrapper `BUILD.gn` |
| `patch_factory.py` | Anchored patch: wires the factory into `rtc_peerconnection_factory_impl.cc` |
| `apply_patch.sh` | Copies files + applies both patches to a wrapper checkout |
| `test/vaapi_h264_bitstream_test.cc` | Standalone unit test for the bitstream converter (`g++ ... && ./a.out` → ALL PASS) |

## The full build, step by step

### 0. Machine setup (Arch) — missing packages + swap

```bash
sudo pacman -S --needed gn ninja clang lld base-devel \
  gstreamer gst-plugins-base gst-plugins-bad \
  libva libva-mesa-driver

# NOTE: there is no separate `gstreamer-vaapi` package on Arch anymore —
# VAAPI decoding is built into gst-plugins-bad (>= 1.20) as the `vah264dec`
# element. You already have it if `gst-inspect-1.0 vah264dec` prints details.

# 7.2 GB RAM is tight for the final giant .so link — add swap FIRST:
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
free -h | head -2   # verify

# Verify VAAPI decode actually works on this machine (element is `vah264dec`
# on GStreamer >= 1.20 / modern Arch, `vaapih264dec` on old gstreamer-vaapi):
gst-inspect-1.0 vah264dec 2>&1 | head -3      # must print "Factory Details"
```

### 1. Checkout the fork (from the webrtc-sdk README)

```bash
# The checkout + build live inside this project (was ~/libwebrtc_build):
#   native/libwebrtc_build = the webrtc src checkout + out-debug build dir
#   native/libwebrtc-vaapi  = the webrtc-sdk/libwebrtc wrapper fork (origin)
cd native/libwebrtc_build

# depot_tools provides gclient (kept in ~/depot_tools — general tool)
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
export PATH="$HOME/depot_tools:$PATH"

# .gclient pointing at the exact m144_release branch
cat > .gclient <<'EOF'
solutions = [
  {
    "name"        : 'src',
    "url"         : 'https://github.com/webrtc-sdk/webrtc.git@m144_release',
    "deps_file"   : 'DEPS',
    "managed"     : False,
    "custom_deps" : { },
    "custom_vars" : { },
  },
]
target_os  = ['linux']
EOF

gclient sync --no-history   # ~10 GB of WebRTC source; allow an hour

# The wrapper (this is what we patch)
cd src
git clone https://github.com/webrtc-sdk/libwebrtc
git apply libwebrtc/patches/custom_audio_source_m144.patch
```

### 2. Patch webrtc's BUILD.gn to include the wrapper

```bash
# In src/BUILD.gn, change group("default") to also build //libwebrtc:
#   deps = [ ":webrtc" ]  →  deps = [ ":webrtc", "//libwebrtc" ]
```

### 3. Apply OUR patch

```bash
cd native/libwebrtc_build/src/libwebrtc
bash ../../../vaapi_patch/apply_patch.sh
```

### 4. Build

```bash
cd native/libwebrtc_build/src
export ARCH=x64
gn gen out-debug/Linux-$ARCH --args="target_os=\"linux\" target_cpu=\"$ARCH\" is_debug=true rtc_include_tests=false rtc_use_h264=true ffmpeg_branding=\"Chrome\" is_component_build=false use_rtti=true use_custom_libcxx=false rtc_enable_protobuf=false"
ninja -C out-debug/Linux-x64 -j2 libwebrtc
# ~1–3 h on 2 cores. OOM → ninja -j1 or more swap.
```

### 5. Swap the custom .so into the flutter_webrtc plugin

```bash
# The plugin is a local clone (path dependency) with the .so vendored here:
cp native/libwebrtc_build/src/out-debug/Linux-x64/libwebrtc.so \
   packages/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.so
# Its third_party/CMakeLists.txt has a guard: a present libwebrtc.so is used
# as-is and never re-downloaded/overwritten.

flutter pub get && flutter run -d linux
```

### 6. Verify + A/B

- Start a stream; stats overlay **Decoder** row:
  - `GStreamerVaapiH264` = VAAPI is live ✅
  - `FFmpegVideoDecoder` = software (either VAAPI failed or you forced it)
- A/B switch:
  ```bash
  OPENNOW_DECODER=software flutter run -d linux   # force software
  flutter run -d linux                            # hardware
  ```
- `Decode/frame` should drop dramatically (from 8–14 ms toward ~1–2 ms).

## Caveats (honest)

- The C++ was written against the actual m144 headers (verified: `Configure` is
  pure virtual, `Decoded(VideoFrame&)` takes a non-const ref, 3-arg `Decode`,
  `Environment`-based factory `Create`). The riskiest logic — the AVCC→Annex-B
  conversion and SPS/PPS injection — is unit-tested and passes. The full .cc
  cannot be compiled in this sandbox (needs the WebRTC checkout).
- A VAAPI decoder element must be present (`vah264dec` from gst-plugins-bad
  >= 1.20, or `vaapih264dec` from the legacy gstreamer-vaapi package) or the
  factory falls back to software and you'd never know — the stats overlay
  will show it. The patch resolves the element name at runtime.
- Every `flutter pub get` may re-extract the plugin, re-running step 5.
