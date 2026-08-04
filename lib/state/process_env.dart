import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'user_settings.dart' show DecoderBackend, RendererBackend;

/// libc `setenv`/`unsetenv` bound via dart:ffi.
///
/// The custom libwebrtc decoder factory reads the process environment variable
/// `OPENNOW_DECODER` (`ForceSoftwareDecoder()` in vaapi_video_decoder.cc) *at
/// decoder instantiation time*. So setting that variable in the current process
/// right before a stream session starts is enough to flip between the GStreamer
/// VAAPI and FFmpeg software decode paths at runtime — no libwebrtc rebuild and
/// no app relaunch with a shell env var.
final class Libc {
  Libc._();

  static final DynamicLibrary _lib = DynamicLibrary.process();

  static final _SetenvDart _setenv =
      _lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv');

  static final _UnsetenvDart _unsetenv =
      _lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv');

  static void setValue(String name, String value) {
    final n = name.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      _setenv(n, v, 1);
    } finally {
      malloc.free(n);
      malloc.free(v);
    }
  }

  static void unset(String name) {
    final n = name.toNativeUtf8();
    try {
      _unsetenv(n);
    } finally {
      malloc.free(n);
    }
  }
}

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);

typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);


/// Applies the selected [backend] to the current process's `OPENNOW_DECODER`
/// environment variable, which the custom libwebrtc decoder factory reads when
/// it instantiates the next decoder. No-op on non-Linux platforms.
///
/// Must be called *before* the peer connection / incoming video track is set
/// up for a session so the factory picks the requested path.
void applyDecoderBackend(DecoderBackend backend) {
  if (!Platform.isLinux) return;
  switch (backend) {
    case DecoderBackend.vaapi:
      // Anything other than "software" keeps the VAAPI-first path, which still
      // auto-falls back to FFmpeg when VAAPI is unavailable.
      Libc.setValue('OPENNOW_DECODER', 'vaapi');
    case DecoderBackend.ffmpeg:
      // The factory special-cases exactly "software" to force the FFmpeg
      // software decoder.
      Libc.setValue('OPENNOW_DECODER', 'software');
  }
}

/// Applies the selected [backend] to the process's `OPENNOW_RENDERER` env
/// var, which the Linux flutter_webrtc plugin reads when the video texture is
/// created (FlutterVideoRendererGL::IsEnabled). "gl" opts into the GPU shader
/// renderer; anything else keeps the CPU ConvertToARGB path. Must be set
/// before the RTCVideoView texture is created for the session.
void applyRendererBackend(RendererBackend backend) {
  if (!Platform.isLinux) return;
  switch (backend) {
    case RendererBackend.cpu:
      // The plugin's IsEnabled() special-cases exactly "gl"; anything else
      // (including unset) uses the stock CPU pixel-buffer renderer.
      Libc.setValue('OPENNOW_RENDERER', 'cpu');
    case RendererBackend.gl:
      Libc.setValue('OPENNOW_RENDERER', 'gl');
  }
}
