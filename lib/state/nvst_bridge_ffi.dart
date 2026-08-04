import 'dart:ffi';
import 'dart:io' show File, Platform;

import 'package:ffi/ffi.dart';

/// dart:ffi bindings for `native/nvst_bridge/nvst_bridge.{h,c}` — the classic
/// NVST UDP video bridge (port of OpenNOW's native streamer). Receives GFN
/// video over the classic Mjolnir UDP path: RTSP SETUP/PLAY → SRTP →
/// NV_VIDEO_PACKET → Annex-B AUs → VAAPI/D3D11 hardware decode → RGBA frames.
///
/// All callbacks are `NativeCallable.listener`s, marshalled onto the creating
/// isolate's event loop (same pattern as [GstBridgeFfi]). Native strings and
/// frame buffers are freed with [freeString]/[freePtr].
class NvstBridgeFfi {
  final DynamicLibrary _lib;
  Pointer<Void> _bridge = nullptr;

  late final _NvstProbeDart _probeFn;
  late final _NvstStartDart _startFn;
  late final _NvstStopDart _stopFn;
  late final _NvstFramesDecodedDart _framesFn;
  late final _NvstFreeStringDart _freeStrFn;
  late final _NvstFreePtrDart _freePtrFn;

  static _NvstFreePtrDart? _freePtrStatic;
  static _NvstFreeStringDart? _freeStrStatic;

  final NativeCallable<_NvstLogCb> _logCallable;
  final NativeCallable<_NvstFrameCb> _frameCallable;

  final void Function(String message) onLog;
  final void Function(int width, int height, int stride, Pointer<Uint8> rgba,
      int rtpTimestamp) onFrame;

  static NvstBridgeFfi? _current;

  NvstBridgeFfi._(
    this._lib, {
    required this.onLog,
    required this.onFrame,
  })  : _logCallable = NativeCallable<_NvstLogCb>.listener(_logTrampoline),
        _frameCallable =
            NativeCallable<_NvstFrameCb>.listener(_frameTrampoline) {
    _probeFn = _lib.lookupFunction<_NvstProbeNative, _NvstProbeDart>(
      'nvst_probe',
    );
    _startFn = _lib.lookupFunction<_NvstStartNative, _NvstStartDart>(
      'nvst_video_start',
    );
    _stopFn = _lib.lookupFunction<_NvstStopNative, _NvstStopDart>(
      'nvst_video_stop',
    );
    _framesFn = _lib.lookupFunction<_NvstFramesDecodedNative,
        _NvstFramesDecodedDart>('nvst_frames_decoded');
    _freeStrFn = _lib.lookupFunction<_NvstFreeStringNative, _NvstFreeStringDart>(
      'nvst_free_string',
    );
    _freePtrFn = _lib.lookupFunction<_NvstFreePtrNative, _NvstFreePtrDart>(
      'nvst_free_ptr',
    );
    _freePtrStatic = _freePtrFn;
    _freeStrStatic = _freeStrFn;
    _current = this;
  }

  /// Loads the library and prepares the listener callables. The bridge handle
  /// is created lazily by [startVideo] (the probe runs first).
  factory NvstBridgeFfi.create({
    required void Function(String message) onLog,
    required void Function(int width, int height, int stride,
        Pointer<Uint8> rgba, int rtpTimestamp) onFrame,
  }) {
    return NvstBridgeFfi._(
      _openLibrary(),
      onLog: onLog,
      onFrame: onFrame,
    );
  }

  static void _logTrampoline(Pointer<Void> userdata, Pointer<Utf8> message) {
    final text = message.toDartString();
    _freeStrStatic?.call(message);
    _current?.onLog(text);
  }

  static void _frameTrampoline(Pointer<Void> userdata, int width, int height,
      int stride, Pointer<Uint8> rgba, int rtpTimestamp) {
    final current = _current;
    if (current == null) {
      _freePtrStatic?.call(rgba.cast());
      return;
    }
    current.onFrame(width, height, stride, rgba, rtpTimestamp);
  }

  static DynamicLibrary _openLibrary() {
    final override = Platform.environment['NVST_BRIDGE_LIB'];
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    final tried = <String>[];
    for (final candidate in _libraryCandidates()) {
      tried.add(candidate.path);
      if (candidate.existsSync()) {
        return DynamicLibrary.open(candidate.absolute.path);
      }
    }
    try {
      return DynamicLibrary.open('libnvst_bridge.so');
    } catch (_) {
      throw StateError(
        'Could not find libnvst_bridge.so. Build it first:\n'
        '  make -C native/nvst_bridge\n'
        'or point NVST_BRIDGE_LIB at an existing build.\n'
        'Looked for:\n  ${tried.join('\n  ')}',
      );
    }
  }

  static List<File> _libraryCandidates() {
    return [
      File('native/nvst_bridge/build/libnvst_bridge.so'),
      File('native/nvst_bridge/libnvst_bridge.so'),
    ];
  }

  /// Runs the RTSP-over-WSS handshake. On success returns the negotiated video
  /// session params; on failure throws with the server's error text.
  NvstVideoSessionParams probe({
    required String rtspsEndpoint,
    required String sessionId,
    required int width,
    required int height,
    required int fps,
    required String codec,
  }) {
    final endpoint = rtspsEndpoint.toNativeUtf8();
    final sid = sessionId.toNativeUtf8();
    final codecU = codec.toNativeUtf8();
    final result = calloc<NvstProbeResult>();
    try {
      final rc = _probeFn(
        endpoint,
        sid,
        width,
        height,
        fps,
        codecU,
        result,
        _logCallable.nativeFunction,
        nullptr,
      );
      final res = result.ref;
      if (rc != 0 || res.ok == 0) {
        throw StateError('NVST RTSP probe failed: ${_cstr(res.error, 256)}');
      }
      return NvstVideoSessionParams(
        clientUdpPort: res.client_udp_port,
        videoPeerIp: _cstr(res.video_peer_ip, 64),
        videoPeerPort: res.video_peer_port,
        srtpAesKeyHex: _cstr(res.srtp_aes_key_hex, 65),
        srtpKeyId: res.srtp_key_id,
        pingPayload: _cstr(res.ping_payload, 64),
        codec: _cstr(res.codec, 8),
      );
    } finally {
      malloc.free(endpoint);
      malloc.free(sid);
      malloc.free(codecU);
      calloc.free(result);
    }
  }

  /// Starts the UDP receive + decode pipeline for a [NvstVideoSessionParams]
  /// returned by [probe].
  void startVideo(NvstVideoSessionParams session) {
    final s = calloc<NvstVideoSession>();
    try {
      s.ref.client_udp_port = session.clientUdpPort;
      _writeFixed(s.ref.video_peer_ip, 64, session.videoPeerIp);
      _writeFixed(s.ref.srtp_aes_key_hex, 65, session.srtpAesKeyHex);
      _writeFixed(s.ref.ping_payload, 64, session.pingPayload);
      _writeFixed(s.ref.codec, 8, session.codec);
      s.ref.video_peer_port = session.videoPeerPort;
      s.ref.srtp_key_id = session.srtpKeyId;

      _bridge = _startFn(
        s,
        _logCallable.nativeFunction,
        _frameCallable.nativeFunction,
        nullptr,
      );
      if (_bridge == nullptr) {
        throw StateError(
          'nvst_video_start returned NULL — see logs for the pipeline error',
        );
      }
    } finally {
      calloc.free(s);
    }
  }

  int framesDecoded() => _framesFn(_bridge);

  void stop() {
    if (_bridge == nullptr) return;
    _stopFn(_bridge);
    _bridge = nullptr;
  }

  void dispose() {
    stop();
    _logCallable.close();
    _frameCallable.close();
    if (identical(_current, this)) _current = null;
  }

  void freeString(Pointer<Utf8> s) => _freeStrFn(s);
  void freePtr(Pointer<Void> p) => _freePtrFn(p);

  static String _cstr(Array<Uint8> arr, int size) {
    var end = 0;
    while (end < size && arr[end] != 0) {
      end++;
    }
    final out = StringBuffer();
    for (var i = 0; i < end; i++) {
      out.writeCharCode(arr[i]);
    }
    return out.toString();
  }

  static void _writeFixed(Array<Uint8> arr, int size, String text) {
    final n = text.length < size - 1 ? text.length : size - 1;
    for (var i = 0; i < n; i++) {
      arr[i] = text.codeUnitAt(i);
    }
    arr[n] = 0;
    for (var i = n + 1; i < size; i++) {
      arr[i] = 0;
    }
  }
}

/// Result of the RTSP probe — feeds [NvstBridgeFfi.startVideo].
class NvstVideoSessionParams {
  final int clientUdpPort;
  final String videoPeerIp;
  final int videoPeerPort;
  final String srtpAesKeyHex;
  final int srtpKeyId;
  final String pingPayload;
  final String codec;

  const NvstVideoSessionParams({
    required this.clientUdpPort,
    required this.videoPeerIp,
    required this.videoPeerPort,
    required this.srtpAesKeyHex,
    required this.srtpKeyId,
    required this.pingPayload,
    required this.codec,
  });
}

// --- C ABI (must match nvst_bridge.h) ---------------------------------------

final class NvstProbeResult extends Struct {
  @Int32()
  external int ok;
  @Array(256)
  external Array<Uint8> error;
  @Array(128)
  external Array<Uint8> session;
  @Array(64)
  external Array<Uint8> video_peer_ip;
  @Uint16()
  external int video_peer_port;
  @Uint16()
  external int client_udp_port;
  @Array(65)
  external Array<Uint8> srtp_aes_key_hex;
  @Uint32()
  external int srtp_key_id;
  @Array(64)
  external Array<Uint8> ping_payload;
  @Array(8)
  external Array<Uint8> codec;
}

final class NvstVideoSession extends Struct {
  @Uint16()
  external int client_udp_port;
  @Array(64)
  external Array<Uint8> video_peer_ip;
  @Uint16()
  external int video_peer_port;
  @Array(65)
  external Array<Uint8> srtp_aes_key_hex;
  @Uint32()
  external int srtp_key_id;
  @Array(64)
  external Array<Uint8> ping_payload;
  @Array(8)
  external Array<Uint8> codec;
}

typedef _NvstLogCb = Void Function(Pointer<Void> userdata, Pointer<Utf8> message);
typedef _NvstFrameCb = Void Function(Pointer<Void> userdata, Int32 width,
    Int32 height, Int32 stride, Pointer<Uint8> rgba, Uint32 rtpTimestamp);

typedef _NvstProbeNative = Int32 Function(
    Pointer<Utf8> rtsps_endpoint,
    Pointer<Utf8> session_id,
    Int32 width,
    Int32 height,
    Int32 fps,
    Pointer<Utf8> codec,
    Pointer<NvstProbeResult> out,
    Pointer<NativeFunction<_NvstLogCb>> log_cb,
    Pointer<Void> userdata);
typedef _NvstProbeDart = int Function(
    Pointer<Utf8> rtsps_endpoint,
    Pointer<Utf8> session_id,
    int width,
    int height,
    int fps,
    Pointer<Utf8> codec,
    Pointer<NvstProbeResult> out,
    Pointer<NativeFunction<_NvstLogCb>> log_cb,
    Pointer<Void> userdata);

typedef _NvstStartNative = Pointer<Void> Function(
    Pointer<NvstVideoSession> session,
    Pointer<NativeFunction<_NvstLogCb>> log_cb,
    Pointer<NativeFunction<_NvstFrameCb>> frame_cb,
    Pointer<Void> userdata);
typedef _NvstStartDart = Pointer<Void> Function(
    Pointer<NvstVideoSession> session,
    Pointer<NativeFunction<_NvstLogCb>> log_cb,
    Pointer<NativeFunction<_NvstFrameCb>> frame_cb,
    Pointer<Void> userdata);

typedef _NvstStopNative = Void Function(Pointer<Void>);
typedef _NvstStopDart = void Function(Pointer<Void>);

typedef _NvstFramesDecodedNative = Int32 Function(Pointer<Void>);
typedef _NvstFramesDecodedDart = int Function(Pointer<Void>);

typedef _NvstFreeStringNative = Void Function(Pointer<Utf8>);
typedef _NvstFreeStringDart = void Function(Pointer<Utf8>);

typedef _NvstFreePtrNative = Void Function(Pointer<Void>);
typedef _NvstFreePtrDart = void Function(Pointer<Void>);
