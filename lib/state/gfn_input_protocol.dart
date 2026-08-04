import 'dart:convert' show utf8;
import 'dart:math' as math;
import 'dart:typed_data';

/// GFN NVST input protocol — port of OpenNOW's `packetEncoding.ts` +
/// `inputSessionClock.ts` + `gamepadMapping.ts` constants.
///
/// Packets are sent over the negotiated `input_channel_v1` (reliable) and
/// `input_channel_partially_reliable` data channels. The server opens the
/// session by sending a handshake message on the reliable channel
/// (firstWord 0x020e/526 with a protocol version), after which the client
/// starts a heartbeat and streams input events.

// --- Input event types -------------------------------------------------------
const int inputHeartbeat = 2;
const int inputKeyDown = 3;
const int inputKeyUp = 4;
const int inputLockKeysSync = 19;
const int inputMouseAbs = 5;
const int inputMouseRel = 7;
const int inputMouseButtonDown = 8;
const int inputMouseButtonUp = 9;
const int inputMouseWheel = 10;
const int inputGamepad = 12;
const int inputHapticsEnabled = 13;
const int inputText = 23;

// --- Protocol v3 wrapper markers ---------------------------------------------
const int wrapperVersionMarker = 0x23;
const int wrapperSingleInput = 0x22;
const int wrapperVersionHeaderBytes = 9;
const int wrapperSingleBodyOffset = wrapperVersionHeaderBytes + 1;

// --- Mouse buttons (1-based for GFN protocol) --------------------------------
const int mouseLeft = 1;
const int mouseMiddle = 2;
const int mouseRight = 3;
const int mouseBack = 4;
const int mouseForward = 5;

// --- XInput gamepad button flags ---------------------------------------------
const int gamepadDpadUp = 0x0001;
const int gamepadDpadDown = 0x0002;
const int gamepadDpadLeft = 0x0004;
const int gamepadDpadRight = 0x0008;
const int gamepadStart = 0x0010;
const int gamepadBack = 0x0020;
const int gamepadLs = 0x0040;
const int gamepadRs = 0x0080;
const int gamepadLb = 0x0100;
const int gamepadRb = 0x0200;
const int gamepadGuide = 0x0400;
const int gamepadA = 0x1000;
const int gamepadB = 0x2000;
const int gamepadX = 0x4000;
const int gamepadY = 0x8000;

const int gamepadMaxControllers = 4;
const int gamepadPacketSize = 38;
const double gamepadDeadzone = 0.15;

/// INPUT_TEXT chunking (port of OpenNOW's packetEncoding.ts).
const int textInputHeaderBytes = 5; // [0x22][u32 LE type]
const int textInputChunkMaxBytes = 1016;

/// Partially-reliable routing masks (port of OpenNOW's
/// `PARTIALLY_RELIABLE_*` constants).
const int partiallyReliableGamepadMaskAll = (1 << gamepadMaxControllers) - 1;
const int partiallyReliableHidDeviceMaskAll = 0xFFFFFFFF;

/// Session-relative input clock (port of `inputSessionClock.ts`). Reset when
/// the input handshake completes; all event timestamps are relative to it.
///
/// Uses a monotonic [Stopwatch] rather than wall-clock time so NTP syncs or
/// manual clock changes can't jump the session timeline backwards (which the
/// server would read as malformed input ordering).
class InputSessionClock {
  final Stopwatch _stopwatch = Stopwatch();

  void start([int? nowMs]) {
    _stopwatch
      ..reset()
      ..start();
  }

  /// Session-relative capture timestamp in microseconds.
  int captureTimestampUs([int? sourceMs]) {
    return _stopwatch.elapsedMicroseconds.clamp(0, 1 << 62);
  }
}

/// Port of OpenNOW's `InputEncoder` (packetEncoding.ts).
class GfnInputEncoder {
  int _protocolVersion = 2;
  final InputSessionClock _clock = InputSessionClock();
  final Map<int, int> _gamepadSequence = {};

  int get protocolVersion => _protocolVersion;
  InputSessionClock get clock => _clock;

  void setProtocolVersion(int version) => _protocolVersion = version;

  int getNextGamepadSequence(int index) {
    final current = _gamepadSequence[index] ?? 1;
    _gamepadSequence[index] = (current + 1) % 65536;
    return current;
  }

  /// Heartbeat is sent RAW — no v3 wrapper (port of OpenNOW's `Jc()`).
  Uint8List encodeHeartbeat() {
    final data = ByteData(4);
    data.setUint32(0, inputHeartbeat, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List encodeLockKeysSync(int state) {
    final data = ByteData(5);
    data.setUint32(0, inputLockKeysSync, Endian.little);
    data.setUint8(4, state & 0xff);
    return _wrapSingle(data.buffer.asUint8List());
  }

  Uint8List encodeKeyDown({
    required int keycode,
    required int scancode,
    required int modifiers,
    required int timestampUs,
  }) {
    return _encodeKey(
      inputKeyDown,
      keycode: keycode,
      scancode: scancode,
      modifiers: modifiers,
      timestampUs: timestampUs,
    );
  }

  Uint8List encodeKeyUp({
    required int keycode,
    required int scancode,
    required int modifiers,
    required int timestampUs,
  }) {
    return _encodeKey(
      inputKeyUp,
      keycode: keycode,
      scancode: scancode,
      modifiers: modifiers,
      timestampUs: timestampUs,
    );
  }

  /// [type u32 LE][dx i16 BE][dy i16 BE][reserved 6B BE][timestamp 8B BE]
  Uint8List encodeMouseMove({
    required int dx,
    required int dy,
    required int timestampUs,
  }) {
    final data = ByteData(22);
    data.setUint32(0, inputMouseRel, Endian.little);
    data.setInt16(4, dx, Endian.big);
    data.setInt16(6, dy, Endian.big);
    data.setUint16(8, 0, Endian.big);
    data.setUint32(10, 0, Endian.big);
    data.setUint64(14, timestampUs, Endian.big);
    return _wrapMouseMove(data.buffer.asUint8List());
  }

  Uint8List encodeMouseButtonDown({
    required int button,
    required int timestampUs,
  }) {
    return _encodeMouseButton(
      inputMouseButtonDown,
      button: button,
      timestampUs: timestampUs,
    );
  }

  Uint8List encodeMouseButtonUp({
    required int button,
    required int timestampUs,
  }) {
    return _encodeMouseButton(
      inputMouseButtonUp,
      button: button,
      timestampUs: timestampUs,
    );
  }

  /// [type u32 LE][horiz i16 BE][vert i16 BE][reserved 6B BE][timestamp 8B BE]
  Uint8List encodeMouseWheel({
    required int delta,
    required int timestampUs,
  }) {
    final data = ByteData(22);
    data.setUint32(0, inputMouseWheel, Endian.little);
    data.setInt16(4, 0, Endian.big);
    data.setInt16(6, delta, Endian.big);
    data.setUint16(8, 0, Endian.big);
    data.setUint32(10, 0, Endian.big);
    data.setUint64(14, timestampUs, Endian.big);
    return _wrapSingle(data.buffer.asUint8List());
  }

  /// Port of OpenNOW's `gl()` — 38-byte XInput-style gamepad packet (all LE).
  Uint8List encodeGamepadState({
    required int controllerId,
    required int buttons,
    required int leftTrigger,
    required int rightTrigger,
    required int leftStickX,
    required int leftStickY,
    required int rightStickX,
    required int rightStickY,
    required int bitmap,
    required bool usePartiallyReliable,
  }) {
    final data = ByteData(gamepadPacketSize);
    data.setUint32(0, inputGamepad, Endian.little);
    data.setUint16(4, 26, Endian.little); // payload size
    data.setUint16(6, controllerId & 0x03, Endian.little);
    data.setUint16(8, bitmap, Endian.little);
    data.setUint16(10, 20, Endian.little); // inner payload size
    data.setUint16(12, buttons, Endian.little);
    data.setUint16(
      14,
      (leftTrigger & 0xff) | ((rightTrigger & 0xff) << 8),
      Endian.little,
    );
    data.setInt16(16, leftStickX, Endian.little);
    data.setInt16(18, leftStickY, Endian.little);
    data.setInt16(20, rightStickX, Endian.little);
    data.setInt16(22, rightStickY, Endian.little);
    data.setUint16(24, 0, Endian.little); // reserved
    data.setUint16(26, 85, Endian.little); // magic 0x55
    data.setUint16(28, 0, Endian.little); // reserved
    data.setUint64(30, _clock.captureTimestampUs(), Endian.little);

    final bytes = data.buffer.asUint8List();
    if (usePartiallyReliable) {
      final seq = getNextGamepadSequence(controllerId);
      return _wrapGamepadPr(bytes, controllerId, seq);
    }
    return _wrapGamepadReliable(bytes);
  }

  /// Port of OpenNOW's `encodeTextInput()` — [INPUT_TEXT] raw UTF-8 chunks.
  /// [0x22][u32 LE INPUT_TEXT][utf8 text], split at UTF-8 boundaries so a
  /// multi-byte rune never straddles two packets.
  List<Uint8List> encodeTextInput(String text) {
    final utf8Bytes = utf8.encode(text);
    final chunks = <Uint8List>[];

    for (var offset = 0; offset < utf8Bytes.length;) {
      final chunkLength = _textInputChunkLength(utf8Bytes, offset);
      if (chunkLength <= 0) break;

      final out = Uint8List(textInputHeaderBytes + chunkLength);
      final view = ByteData.sublistView(out);
      out[0] = wrapperSingleInput;
      view.setUint32(1, inputText, Endian.little);
      out.setRange(textInputHeaderBytes, out.length, utf8Bytes, offset);
      chunks.add(out);
      offset += chunkLength;
    }

    return chunks;
  }

  int _textInputChunkLength(Uint8List bytes, int offset) {
    final remaining = bytes.length - offset;
    if (remaining <= textInputChunkMaxBytes) return remaining;

    var end = offset + textInputChunkMaxBytes;
    for (var attempt = 0; attempt < 4; attempt++) {
      if ((bytes[end] & 0xc0) != 0x80) return end - offset;
      end--;
    }
    return 0;
  }

  // --- Private encoders -------------------------------------------------------

  Uint8List _encodeKey(
    int type, {
    required int keycode,
    required int scancode,
    required int modifiers,
    required int timestampUs,
  }) {
    final data = ByteData(18);
    data.setUint32(0, type, Endian.little);
    data.setUint16(4, keycode & 0xffff, Endian.big);
    data.setUint16(6, modifiers & 0xffff, Endian.big);
    data.setUint16(8, scancode & 0xffff, Endian.big);
    data.setUint64(10, timestampUs, Endian.big);
    return _wrapSingle(data.buffer.asUint8List());
  }

  Uint8List _encodeMouseButton(
    int type, {
    required int button,
    required int timestampUs,
  }) {
    final data = ByteData(18);
    data.setUint32(0, type, Endian.little);
    data.setUint8(4, button);
    data.setUint8(5, 0);
    data.setUint32(6, 0, Endian.big);
    data.setUint64(10, timestampUs, Endian.big);
    return _wrapSingle(data.buffer.asUint8List());
  }

  // --- Protocol v3+ wrappers ---------------------------------------------------

  /// [0x23][8B timestamp BE][0x22][payload] — single-event wrapper.
  Uint8List _wrapSingle(Uint8List payload) {
    if (_protocolVersion <= 2) return payload;
    final out = Uint8List(wrapperVersionHeaderBytes + 1 + payload.length);
    final view = ByteData.sublistView(out);
    out[0] = wrapperVersionMarker;
    view.setUint64(1, _clock.captureTimestampUs(), Endian.big);
    out[wrapperVersionHeaderBytes] = wrapperSingleInput;
    out.setRange(wrapperSingleBodyOffset, out.length, payload);
    return out;
  }

  /// [0x23][8B timestamp BE][0x21][2B length BE][payload] — mouse/cursor wrapper.
  Uint8List _wrapMouseMove(Uint8List payload) {
    if (_protocolVersion <= 2) return payload;
    final out = Uint8List(wrapperVersionHeaderBytes + 1 + 2 + payload.length);
    final view = ByteData.sublistView(out);
    out[0] = wrapperVersionMarker;
    view.setUint64(1, _clock.captureTimestampUs(), Endian.big);
    out[9] = 0x21;
    view.setUint16(10, payload.length, Endian.big);
    out.setRange(12, out.length, payload);
    return out;
  }

  /// [0x23][8B ts][0x21][2B size BE][payload] — reliable gamepad wrapper.
  Uint8List _wrapGamepadReliable(Uint8List payload) {
    if (_protocolVersion <= 2) return payload;
    final out = Uint8List(wrapperVersionHeaderBytes + 1 + 2 + payload.length);
    final view = ByteData.sublistView(out);
    out[0] = wrapperVersionMarker;
    view.setUint64(1, _clock.captureTimestampUs(), Endian.big);
    out[9] = 0x21;
    view.setUint16(10, payload.length, Endian.big);
    out.setRange(12, out.length, payload);
    return out;
  }

  /// [0x23][8B ts][0x26][1B idx][2B seq BE][0x21][2B size BE][payload] — PR.
  Uint8List _wrapGamepadPr(Uint8List payload, int index, int seq) {
    if (_protocolVersion <= 2) return payload;
    final out = Uint8List(wrapperVersionHeaderBytes + 1 + 1 + 2 + 1 + 2 + payload.length);
    final view = ByteData.sublistView(out);
    out[0] = wrapperVersionMarker;
    view.setUint64(1, _clock.captureTimestampUs(), Endian.big);
    out[9] = 0x26;
    out[10] = index & 0xff;
    view.setUint16(11, seq, Endian.big);
    out[13] = 0x21;
    view.setUint16(14, payload.length, Endian.big);
    out.setRange(16, out.length, payload);
    return out;
  }
}

/// Apply a radial deadzone to normalized stick values (-1..1).
({double x, double y}) applyDeadzone(double x, double y, [double deadzone = gamepadDeadzone]) {
  final squared = x * x + y * y;
  if (squared < deadzone * deadzone) return (x: 0, y: 0);
  final dist = squared == 0 ? 1.0 : math.sqrt(squared);
  final scaled = ((dist - deadzone) / (1 - deadzone)).clamp(0.0, 1.0);
  return (x: x / dist * scaled, y: y / dist * scaled);
}

/// Normalized -1..1 → signed 16-bit int.
int normalizeToInt16(double value) =>
    (value.clamp(-1.0, 1.0) * 32767).round().clamp(-32768, 32767);

/// Normalized 0..1 trigger → unsigned 8-bit int.
int normalizeToUint8(double value) =>
    (value.clamp(0.0, 1.0) * 255).round().clamp(0, 255);
