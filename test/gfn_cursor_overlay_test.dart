import 'dart:convert' show base64Decode, utf8;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_cursor_overlay.dart';

List<int> uint16Le(int value) => [value & 0xff, (value >> 8) & 0xff];

void main() {
  group('parseGfnCursorChannelMessage', () {
    test('parses predefined cursor updates with optional position', () {
      final bytes = Uint8List.fromList([
        0,
        12,
        0,
        0,
        0,
        ...uint16Le(0),
        ...uint16Le(32768),
        ...uint16Le(65535),
      ]);
      final parsed = parseGfnCursorChannelMessage(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.custom, isFalse);
      expect(parsed.cursorId, 12);
      expect(parsed.positionX, 32768);
      expect(parsed.positionY, 65535);
    });

    test('parses custom cursor image metadata', () {
      final mimeType = utf8.encode('image/png');
      final image = utf8.encode('AAAA');
      final bytes = Uint8List.fromList([
        1,
        7,
        3,
        4,
        mimeType.length,
        ...mimeType,
        ...uint16Le(image.length),
        ...image,
        ...uint16Le(10),
        ...uint16Le(20),
        ...uint16Le(150),
      ]);
      final parsed = parseGfnCursorChannelMessage(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.custom, isTrue);
      expect(parsed.cursorId, 7);
      expect(parsed.hotspotX, 3);
      expect(parsed.hotspotY, 4);
      expect(parsed.mimeType, 'image/png');
      // 'AAAA' base64 decodes to three zero bytes.
      expect(parsed.imageBytes, [0, 0, 0]);
      expect(parsed.positionX, 10);
      expect(parsed.positionY, 20);
      expect(parsed.scale, closeTo(1.5, 1e-9));
    });

    test('rejects truncated custom cursor images', () {
      final bytes = Uint8List.fromList([1, 1, 0, 0, 0, ...uint16Le(4), 65, 65]);
      expect(parseGfnCursorChannelMessage(bytes), isNull);
    });

    test('rejects malformed base64 image payloads instead of throwing', () {
      final mimeType = utf8.encode('image/png');
      final image = utf8.encode('!!!not-base64!!!');
      final bytes = Uint8List.fromList([
        1,
        7,
        0,
        0,
        mimeType.length,
        ...mimeType,
        ...uint16Le(image.length),
        ...image,
      ]);
      expect(parseGfnCursorChannelMessage(bytes), isNull);
    });

    test('accepts a bare predefined message without position or image', () {
      final parsed = parseGfnCursorChannelMessage(Uint8List.fromList([0, 4]));
      expect(parsed, isNotNull);
      expect(parsed!.custom, isFalse);
      expect(parsed.cursorId, 4);
      expect(parsed.positionX, isNull);
      expect(parsed.positionY, isNull);
      expect(parsed.imageBytes, isNull);
    });

    test('rejects unknown message types and empty payloads', () {
      expect(parseGfnCursorChannelMessage(Uint8List.fromList([2, 1])), isNull);
      expect(parseGfnCursorChannelMessage(Uint8List(1)), isNull);
    });

    test('parses a text-delivered message identically to binary', () {
      // The server can deliver cursor payloads as a text message; the channel
      // handler UTF-8 encodes text back to bytes (mirroring OpenNOW's
      // toBytes). For the predefined-id-only form (all-ASCII wire bytes) a
      // text round-trip must yield the same update as the binary form.
      final binary = Uint8List.fromList([0, 5]);
      final text = utf8.decode(binary, allowMalformed: true);
      final viaText = parseGfnCursorChannelMessage(
        Uint8List.fromList(utf8.encode(text)),
      );
      final viaBinary = parseGfnCursorChannelMessage(binary);
      expect(viaText, isNotNull);
      expect(viaText!.cursorId, 5);
      expect(viaText.custom, isFalse);
      expect(viaText.cursorId, viaBinary!.cursorId);
    });
  });

  group('predefinedCursorFor', () {
    test('returns the table entry for known ids', () {
      expect(predefinedCursorFor(1).style, 'default');
      expect(predefinedCursorFor(2).style, 'text');
      expect(predefinedCursorFor(4).style, 'crosshair');
      expect(predefinedCursorFor(0).style, 'none');
    });

    test('falls back to the default arrow for unknown ids', () {
      expect(predefinedCursorFor(99).id, 1);
      expect(predefinedCursorFor(-3).style, 'default');
    });

    test('every bitmap is a decodable 1-bit 32x32 ICO', () {
      for (final cursor in predefinedCursorTable) {
        if (cursor.imageBase64.isEmpty) continue;
        final decoded =
            decodeIcoCursor(base64Decode(cursor.imageBase64));
        expect(decoded, isNotNull,
            reason: 'cursor ${cursor.id} (${cursor.style}) must decode');
        expect(decoded!.width, 32);
        expect(decoded.height, 32);
        // RGBA buffer is exactly width*height*4 bytes.
        expect(decoded.rgba.length, 32 * 32 * 4);
      }
    });

    test('predefined arrow has opaque pixels with a hotspot offset', () {
      final decoded = decodeIcoCursor(
        base64Decode(predefinedCursorFor(1).imageBase64),
      )!;
      // The arrow body must have some fully-opaque pixels (AND mask 0).
      var opaque = 0;
      for (var i = 3; i < decoded.rgba.length; i += 4) {
        if (decoded.rgba[i] == 255) opaque++;
      }
      expect(opaque, greaterThan(0));
      // And some transparent pixels around it (the AND mask).
      expect(opaque, lessThan(32 * 32));
    });

    test('rejects non-ICO payloads', () {
      expect(decodeIcoCursor(Uint8List.fromList([1, 2, 3])), isNull);
      expect(decodeIcoCursor(Uint8List(64)), isNull);
    });
  });

  group('pngPixelSize', () {
    test('reads PNG header dimensions', () {
      final png = Uint8List(24);
      png[0] = 0x89;
      png[1] = 0x50; // PNG signature
      final view = ByteData.sublistView(png);
      view.setUint32(16, 32);
      view.setUint32(20, 32);
      expect(pngPixelSize(png), (32, 32));
    });

    test('returns null for non-PNG or short payloads', () {
      expect(pngPixelSize(Uint8List(24)), isNull);
      expect(pngPixelSize(Uint8List(4)), isNull);
    });
  });
}
