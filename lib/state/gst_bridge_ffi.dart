import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// dart:ffi bindings for `native/gst_bridge/gst_bridge.{h,c}` — the GStreamer
/// `webrtcbin` bridge that gives the app a hardware-decode path (VAAPI /
/// FFmpeg via GStreamer elements) without a custom libwebrtc build.
///
/// All callbacks are `NativeCallable.listener`s: GStreamer fires them from its
/// own threads, and the Dart SDK marshals each invocation onto the creating
/// isolate's event loop, so [onFrame] can directly update Flutter state.
/// Native strings/frames must be freed with [freeString]/[freePtr] exactly
/// once (the frame callback's `rgba` buffer is malloc'd by C).
class GstBridgeFfi {
  final DynamicLibrary _lib;
  late final Pointer<Void> _bridge;

  // Native function pointers.
  late final _BridgeCreateDart _createFn;
  late final _BridgeDestroyDart _destroyFn;
  late final _BridgeSetRemoteOfferDart _offerFn;
  late final _BridgeSetOriginalCredsDart _setCredsFn;
  late final _BridgeAddRemoteIceDart _addIceFn;
  late final _BridgeCreateChannelsDart _channelsFn;
  late final _BridgeSendInputDart _sendFn;
  late final _BridgeFramesDecodedDart _framesFn;
  late final _BridgeFreeStringDart _freeStrFn;
  late final _BridgeFreePtrDart _freePtrFn;

  // Statically reachable free functions: callbacks already queued on the
  // event loop when the bridge is torn down must still reclaim their malloc'd
  // C buffers after [_current] has been cleared. (_freePtrStatic = malloc'd
  // buffers, _freeStrStatic = g_strdup'd strings.)
  static _BridgeFreePtrDart? _freePtrStatic;
  static _BridgeFreeStringDart? _freeStrStatic;

  // Callbacks kept alive for the lifetime of the bridge (owned here, so the
  // function pointers handed to C stay valid).
  final NativeCallable<_BridgeLogCb> _logCallable;
  final NativeCallable<_BridgeIceCb> _iceCallable;
  final NativeCallable<_BridgeFrameCb> _frameCallable;
  final NativeCallable<_BridgeChannelCb> _channelCallable;
  final NativeCallable<_BridgeMessageCb> _messageCallable;

  final void Function(String message) onLog;
  final void Function(int mlineIndex, String candidate) onIceCandidate;
  final void Function(int width, int height, int stride, Pointer<Uint8> rgba,
      int rtpTimestamp) onFrame;
  final void Function(int channel, bool open) onChannel;
  final void Function(int channel, Uint8List data) onMessage;

  // The one live bridge instance (app uses a single stream at a time); static
  // trampolines dispatch through this.
  static GstBridgeFfi? _current;

  GstBridgeFfi._(
    this._lib, {
    required this.onLog,
    required this.onIceCandidate,
    required this.onFrame,
    required this.onChannel,
    required this.onMessage,
  })  : _logCallable = NativeCallable<_BridgeLogCb>.listener(_logTrampoline),
        _iceCallable = NativeCallable<_BridgeIceCb>.listener(_iceTrampoline),
        _frameCallable =
            NativeCallable<_BridgeFrameCb>.listener(_frameTrampoline),
        _channelCallable =
            NativeCallable<_BridgeChannelCb>.listener(_channelTrampoline),
        _messageCallable =
            NativeCallable<_BridgeMessageCb>.listener(_messageTrampoline) {
    _createFn = _lib.lookupFunction<_BridgeCreateNative, _BridgeCreateDart>(
      'bridge_create',
    );
    _destroyFn = _lib.lookupFunction<_BridgeDestroyNative, _BridgeDestroyDart>(
      'bridge_destroy',
    );
    _offerFn = _lib.lookupFunction<
        _BridgeSetRemoteOfferNative,
        _BridgeSetRemoteOfferDart>('bridge_set_remote_offer');
    _setCredsFn = _lib.lookupFunction<
        _BridgeSetOriginalCredsNative,
        _BridgeSetOriginalCredsDart>('bridge_set_original_ice_credentials');
    _addIceFn = _lib.lookupFunction<
        _BridgeAddRemoteIceNative,
        _BridgeAddRemoteIceDart>('bridge_add_remote_ice');
    _channelsFn = _lib.lookupFunction<
        _BridgeCreateChannelsNative,
        _BridgeCreateChannelsDart>('bridge_create_input_channels');
    _sendFn = _lib.lookupFunction<_BridgeSendInputNative, _BridgeSendInputDart>(
      'bridge_send_input',
    );
    _framesFn =
        _lib.lookupFunction<_BridgeFramesDecodedNative, _BridgeFramesDecodedDart>(
      'bridge_frames_decoded',
    );
    _freeStrFn =
        _lib.lookupFunction<_BridgeFreeStringNative, _BridgeFreeStringDart>(
      'bridge_free_string',
    );
    _freePtrFn = _lib.lookupFunction<_BridgeFreePtrNative, _BridgeFreePtrDart>(
      'bridge_free_ptr',
    );
    _freePtrStatic = _freePtrFn;
    _freeStrStatic = _freeStrFn;

    _bridge = _createFn(
      _logCallable.nativeFunction,
      _iceCallable.nativeFunction,
      _frameCallable.nativeFunction,
      _channelCallable.nativeFunction,
      _messageCallable.nativeFunction,
      nullptr,
    );
    if (_bridge == nullptr) {
      // The callables were created in the initializer list — reclaim them so
      // the failure path doesn't leak (they pin the isolate alive).
      _logCallable.close();
      _iceCallable.close();
      _frameCallable.close();
      _channelCallable.close();
      _messageCallable.close();
      throw StateError('gst_bridge: bridge_create returned NULL — is the '
          'webrtcbin plugin installed? (gst-plugins-bad)');
    }
    _bridgeCreated = true;
    _current = this;
  }

  /// Native bridge handle (for the in-tree GPU-texture plugin). Null before
  /// startVideo succeeds.
  int? get bridgePointer {
    if (!_bridgeCreated) return null;
    return _bridge == nullptr ? null : _bridge.address;
  }

  bool _bridgeCreated = false;

  /// Absolute path of the loaded bridge library (for dlopen by the plugin).
  static String? resolvedLibraryPath;

  /// Creates the bridge (allocates the GStreamer pipeline + starts the loop
  /// thread). Throws [StateError] if the library or webrtcbin plugin is
  /// missing. Call [dispose] when done.
  factory GstBridgeFfi.create({
    required void Function(String message) onLog,
    required void Function(int mlineIndex, String candidate) onIceCandidate,
    required void Function(int width, int height, int stride, Pointer<Uint8>
        rgba, int rtpTimestamp) onFrame,
    required void Function(int channel, bool open) onChannel,
    required void Function(int channel, Uint8List data) onMessage,
  }) {
    return GstBridgeFfi._(
      _openLibrary(),
      onLog: onLog,
      onIceCandidate: onIceCandidate,
      onFrame: onFrame,
      onChannel: onChannel,
      onMessage: onMessage,
    );
  }

  // --- Static trampolines (dispatched on the main isolate event loop) -------

  // NOTE: NativeCallable.listener callbacks use the DART representation of
  // the C signature (@DartRepresentationOf): FFI scalar types arrive as their
  // Dart counterparts (Uint32/Int32/IntPtr -> int), pointers stay pointers.
  static void _logTrampoline(Pointer<Void> userdata, Pointer<Utf8> message) {
    // The C side g_strdup'd this for us (async listener); free after reading.
    final text = message.toDartString();
    _freeStrStatic?.call(message);
    _current?.onLog(text);
  }

  static void _iceTrampoline(
      Pointer<Void> userdata, int mlineIndex, Pointer<Utf8> candidate) {
    // g_strdup'd by C; free after reading.
    final text = candidate.toDartString();
    _freeStrStatic?.call(candidate);
    _current?.onIceCandidate(mlineIndex, text);
  }

  static void _frameTrampoline(Pointer<Void> userdata, int width, int height,
      int stride, Pointer<Uint8> rgba, int rtpTimestamp) {
    final current = _current;
    if (current == null) {
      // Bridge was torn down but this callback was already queued on the event
      // loop. Reclaim the C buffer so it doesn't leak; the frame itself is
      // dropped, which is fine during teardown.
      _freePtrStatic?.call(rgba.cast());
      return;
    }
    current.onFrame(width, height, stride, rgba, rtpTimestamp);
  }

  static void _channelTrampoline(
      Pointer<Void> userdata, int channel, int open) {
    _current?.onChannel(channel, open != 0);
  }

  static void _messageTrampoline(
      Pointer<Void> userdata, int channel, Pointer<Uint8> data, int len) {
    if (len <= 0 || data == nullptr) return;
    // malloc'd by C; copy then free.
    final bytes = Uint8List.fromList(data.asTypedList(len));
    _freePtrStatic?.call(data.cast());
    _current?.onMessage(channel, bytes);
  }

  /// Resolves the shared library. Order: explicit env override, repo build
  /// dir (dev), then the system library name (rpath/LD_LIBRARY_PATH). Throws a
  /// [StateError] with a build hint instead of the cryptic "cannot open shared
  /// object file" so a missing bridge is self-diagnosing.
  static DynamicLibrary _openLibrary() {
    final override = Platform.environment['GST_BRIDGE_LIB'];
    if (override != null && override.isNotEmpty) {
      final lib = DynamicLibrary.open(override);
      resolvedLibraryPath = override;
      return lib;
    }
    final tried = <String>[];
    for (final candidate in _libraryCandidates()) {
      tried.add(candidate.path);
      if (candidate.existsSync()) {
        final lib = DynamicLibrary.open(candidate.absolute.path);
        resolvedLibraryPath = candidate.absolute.path;
        return lib;
      }
    }
    try {
      // Installed system-wide (e.g. LD_LIBRARY_PATH or rpath) or a release
      // bundle that copied the .so next to the executable.
      return DynamicLibrary.open('libgst_bridge.so');
    } catch (_) {
      throw StateError(
        'Could not find libgst_bridge.so. Build it first:\n'
        '  make -C native/gst_bridge\n'
        'or point GST_BRIDGE_LIB at an existing build.\n'
        'Looked for:\n  ${tried.join('\n  ')}',
      );
    }
  }

  /// Dev lookup order: repo build dir, then the `make install` copy next to
  /// the sources.
  static List<File> _libraryCandidates() {
    return [
      File('native/gst_bridge/build/libgst_bridge.so'),
      File('native/gst_bridge/libgst_bridge.so'),
    ];
  }

  /// Blocks until GStreamer produces an answer for [offerSdp]. Returns the
  /// answer SDP text, or null on failure.
  String? setRemoteOffer(String offerSdp) {
    final offer = offerSdp.toNativeUtf8();
    try {
      final answer = _offerFn(_bridge, offer);
      if (answer == nullptr) return null;
      try {
        return answer.toDartString();
      } finally {
        freeString(answer);
      }
    } finally {
      malloc.free(offer);
    }
  }

  /// Hands the ORIGINAL (unsanitized) remote ICE credentials to the bridge
  /// so it can restore them on the NICE streams after negotiation. Must be
  /// called before [setRemoteOffer]; GFN's base64-padded ice-pwd is sanitized
  /// for GStreamer's parser but the server's STUN integrity uses the real one.
  void storeOriginalIceCredentials(String ufrag, String pwd) {
    if (ufrag.isEmpty || pwd.isEmpty) return;
    final u = ufrag.toNativeUtf8();
    final p = pwd.toNativeUtf8();
    try {
      _setCredsFn(_bridge, u, p);
    } finally {
      malloc.free(u);
      malloc.free(p);
    }
  }

  void addRemoteIce(String candidate, String? sdpMid, int sdpMLineIndex) {
    final cand = candidate.toNativeUtf8();
    final mid = (sdpMid ?? '').toNativeUtf8();
    try {
      _addIceFn(_bridge, cand, mid, sdpMLineIndex);
    } finally {
      malloc.free(cand);
      malloc.free(mid);
    }
  }

  void createInputChannels(int partialReliableMs) {
    _channelsFn(_bridge, partialReliableMs);
  }

  void sendInput(Uint8List data, {required bool reliable}) {
    if (data.isEmpty) return;
    final buf = malloc.allocate<Uint8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    try {
      _sendFn(_bridge, buf, data.length, reliable ? 1 : 0);
    } finally {
      malloc.free(buf);
    }
  }

  int framesDecoded() => _framesFn(_bridge);

  void freeString(Pointer<Utf8> s) => _freeStrFn(s);

  void freePtr(Pointer<Void> p) => _freePtrFn(p);

  void dispose() {
    _destroyFn(_bridge);
    _logCallable.close();
    _iceCallable.close();
    _frameCallable.close();
    _channelCallable.close();
    _messageCallable.close();
    if (identical(_current, this)) _current = null;
  }
}

// --- C ABI typedefs (must match gst_bridge.h) ------------------------------

typedef _BridgeLogCb = Void Function(
    Pointer<Void> userdata, Pointer<Utf8> message);
typedef _BridgeIceCb = Void Function(
    Pointer<Void> userdata, Uint32 mlineIndex, Pointer<Utf8> candidate);
typedef _BridgeFrameCb = Void Function(Pointer<Void> userdata, Int32 width,
    Int32 height, Int32 stride, Pointer<Uint8> rgba, Uint32 rtpTimestamp);
typedef _BridgeChannelCb = Void Function(
    Pointer<Void> userdata, Int32 channel, Int32 open);
typedef _BridgeMessageCb = Void Function(Pointer<Void> userdata, Int32 channel,
    Pointer<Uint8> data, IntPtr len);

typedef _BridgeCreateNative = Pointer<Void> Function(
    Pointer<NativeFunction<_BridgeLogCb>>,
    Pointer<NativeFunction<_BridgeIceCb>>,
    Pointer<NativeFunction<_BridgeFrameCb>>,
    Pointer<NativeFunction<_BridgeChannelCb>>,
    Pointer<NativeFunction<_BridgeMessageCb>>,
    Pointer<Void>);
typedef _BridgeCreateDart = Pointer<Void> Function(
    Pointer<NativeFunction<_BridgeLogCb>>,
    Pointer<NativeFunction<_BridgeIceCb>>,
    Pointer<NativeFunction<_BridgeFrameCb>>,
    Pointer<NativeFunction<_BridgeChannelCb>>,
    Pointer<NativeFunction<_BridgeMessageCb>>,
    Pointer<Void>);

typedef _BridgeDestroyNative = Void Function(Pointer<Void>);
typedef _BridgeDestroyDart = void Function(Pointer<Void>);

typedef _BridgeSetRemoteOfferNative = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>);
typedef _BridgeSetRemoteOfferDart = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>);

typedef _BridgeSetOriginalCredsNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _BridgeSetOriginalCredsDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _BridgeAddRemoteIceNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _BridgeAddRemoteIceDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _BridgeCreateChannelsNative = Int32 Function(Pointer<Void>, Int32);
typedef _BridgeCreateChannelsDart = int Function(Pointer<Void>, int);

typedef _BridgeSendInputNative = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, IntPtr, Int32);
typedef _BridgeSendInputDart = int Function(
    Pointer<Void>, Pointer<Uint8>, int, int);

typedef _BridgeFramesDecodedNative = Int32 Function(Pointer<Void>);
typedef _BridgeFramesDecodedDart = int Function(Pointer<Void>);

typedef _BridgeFreeStringNative = Void Function(Pointer<Utf8>);
typedef _BridgeFreeStringDart = void Function(Pointer<Utf8>);

typedef _BridgeFreePtrNative = Void Function(Pointer<Void>);
typedef _BridgeFreePtrDart = void Function(Pointer<Void>);
