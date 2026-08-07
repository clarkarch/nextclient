# next_client

A new Flutter project.

## Build notes

- **Custom libwebrtc wrapper** (VAAPI decode + zero-copy render): see
  [`native/README.md`](native/README.md) for the incremental rebuild workflow,
  and [`vaapi_patch/README.md`](vaapi_patch/README.md) for the patch itself.
  The release app ships the locally built `libwebrtc.so`, vendored into
  `packages/flutter_webrtc/third_party/libwebrtc/`.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
