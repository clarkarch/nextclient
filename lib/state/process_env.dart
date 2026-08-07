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

/// Windows `_putenv_s` (UCRT) bound via dart:ffi. The renderer's IsEnabled()
/// and the libwebrtc decoder factory read the variable with `std::getenv`
/// (the C runtime), so the env var must be set through the CRT rather than
/// `SetEnvironmentVariable`, which can leave the CRT's `environ` stale. The
/// symbol is resolved from the process image (Flutter Windows apps link the
/// UCRT dynamically), falling back to explicit ucrtbase/msvcrt loads. If none
/// resolve, the call is a silent no-op (the GPU renderer simply stays off).
final class WindowsEnv {
  WindowsEnv._();

  static int Function(Pointer<Utf8>, Pointer<Utf8>)? _putenv;
  static bool _resolved = false;

  static void _resolve() {
    if (_resolved) return;
    _resolved = true;
    for (final libName in const ['', 'ucrtbase.dll', 'msvcrt.dll']) {
      try {
        final lib = libName.isEmpty
            ? DynamicLibrary.process()
            : DynamicLibrary.open(libName);
        _putenv = lib.lookupFunction<
            _PutenvNative, _PutenvDart>('_putenv_s');
        if (_putenv != null) return;
      } catch (_) {
        // Try the next library.
      }
    }
  }

  static void setValue(String name, String value) {
    _resolve();
    final fn = _putenv;
    if (fn == null) return;
    final n = name.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      fn(n, v);
    } finally {
      malloc.free(n);
      malloc.free(v);
    }
  }
}

typedef _PutenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PutenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>);


/// Applies the selected [backend] to the current process's `OPENNOW_DECODER`
/// environment variable, which the custom libwebrtc decoder factory reads when
/// it instantiates the next decoder. Linux-only (the VAAPI patch); the stock
/// Windows libwebrtc has no such factory hook.
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
/// var, which the flutter_webrtc plugin reads when the video texture is
/// created (FlutterVideoRendererGL::IsEnabled on Linux,
/// FlutterVideoRendererD3D::IsEnabled on Windows). "gl" opts into the GPU
/// shader renderer (GL on Linux, D3D11 shared-handle on Windows); anything
/// else keeps the CPU ConvertToARGB path. Must be set before the RTCVideoView
/// texture is created for the session.
void applyRendererBackend(RendererBackend backend) {
  final value = switch (backend) {
    // The plugin's IsEnabled() special-cases exactly "gl"; anything else
    // (including unset) uses the stock CPU pixel-buffer renderer.
    RendererBackend.cpu => 'cpu',
    RendererBackend.gl => 'gl',
  };
  if (Platform.isLinux) {
    Libc.setValue('OPENNOW_RENDERER', value);
  } else if (Platform.isWindows) {
    WindowsEnv.setValue('OPENNOW_RENDERER', value);
  }
}
