import 'dart:convert' show base64, utf8;
import 'dart:typed_data';

/// In-game cursor overlay — port of OpenNOW's `cursorChannel.ts`.
///
/// NVIDIA's streamer opens a `cursor_channel` data channel and streams the
/// game's actual cursor state over it: predefined styles (the classic arrow /
/// text / crosshair / resize family) and custom bitmaps (base64 PNGs with a
/// hotspot + scale) plus an optional normalized cursor position. Rendering the
/// server's cursor client-side is what makes a cloud game *feel* native —
/// without it the client shows either a plain OS arrow or nothing at all
/// while the game's custom cursor sits in the video stream.

/// One parsed cursor update from the `cursor_channel`.
class GfnCursorOverlayUpdate {
  /// Server cursor id. For predefined cursors this indexes the fixed style
  /// table (see [predefinedCursorTable]); for custom cursors it is opaque.
  final int cursorId;

  /// True when the update carries a custom bitmap; false for a predefined
  /// style id.
  final bool custom;

  /// Hotspot in bitmap pixels (the point of the cursor that tracks the
  /// pointer), when the message included it.
  final int? hotspotX;
  final int? hotspotY;

  /// Image MIME type (e.g. "image/png") for custom cursors.
  final String? mimeType;

  /// Decoded bitmap bytes (PNG/JPEG/…) for custom cursors.
  final Uint8List? imageBytes;

  /// Normalized cursor position in 0..65535 space, when the server sent one.
  /// Only meaningful when the cursor transitions from hidden to visible.
  final int? positionX;
  final int? positionY;

  /// Cursor scale (1.0 = native size), for custom cursors.
  final double? scale;

  const GfnCursorOverlayUpdate({
    required this.cursorId,
    required this.custom,
    this.hotspotX,
    this.hotspotY,
    this.mimeType,
    this.imageBytes,
    this.positionX,
    this.positionY,
    this.scale,
  });
}

int _readUint16Le(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

/// Port of OpenNOW's `parseGfnCursorChannelMessage`.
///
/// Wire layout (all multi-byte LE):
/// `[type u8][cursorId u8][hotspotX u8][hotspotY u8][mimeLen u8]`
/// `[mimeType utf8…][imageLen u16][image base64 utf8…]`
/// `[posX u16][posY u16]` (optional) `[scale u16 /100]` (custom only).
///
/// A message shorter than 5 bytes with type 0 is still valid: it selects a
/// predefined cursor with no position/image payload.
GfnCursorOverlayUpdate? parseGfnCursorChannelMessage(Uint8List bytes) {
  if (bytes.length < 2) return null;
  final messageType = bytes[0];
  if (messageType != 0 && messageType != 1) return null;
  final cursorId = bytes[1];

  if (bytes.length < 5) {
    return messageType == 0
        ? GfnCursorOverlayUpdate(cursorId: cursorId, custom: false)
        : null;
  }

  final hotspotX = bytes[2];
  final hotspotY = bytes[3];
  final mimeTypeLength = bytes[4];
  var offset = 5;
  if (offset + mimeTypeLength > bytes.length) return null;
  final mimeType = utf8.decode(
    bytes.sublist(offset, offset + mimeTypeLength),
    allowMalformed: true,
  );
  offset += mimeTypeLength;

  if (offset + 2 > bytes.length) return null;
  final imageLength = _readUint16Le(bytes, offset);
  offset += 2;
  if (offset + imageLength > bytes.length) return null;
  final imageBase64 = utf8.decode(
    bytes.sublist(offset, offset + imageLength),
    allowMalformed: true,
  );
  offset += imageLength;

  int? positionX;
  int? positionY;
  if (offset + 4 <= bytes.length) {
    positionX = _readUint16Le(bytes, offset);
    positionY = _readUint16Le(bytes, offset + 2);
    offset += 4;
  }

  double? scale;
  if (messageType == 1 && offset + 2 <= bytes.length) {
    scale = _readUint16Le(bytes, offset) / 100;
  }

  // base64.decode throws FormatException on corrupted payloads — treat a bad
  // image as a parse failure (skip the update) instead of throwing out of the
  // channel handler.
  Uint8List? imageBytes;
  if (imageBase64.isNotEmpty) {
    try {
      imageBytes = base64.decode(imageBase64);
    } on FormatException {
      return null;
    }
  }

  return GfnCursorOverlayUpdate(
    cursorId: cursorId,
    custom: messageType == 1,
    hotspotX: hotspotX,
    hotspotY: hotspotY,
    mimeType: mimeType,
    imageBytes: imageBytes,
    positionX: positionX,
    positionY: positionY,
    scale: scale,
  );
}

/// Reads the pixel dimensions from a PNG header (IHDR at offset 16/20, u32
/// big-endian) so a cursor bitmap can be rendered at native device-pixel
/// resolution on any display scale. Returns null for non-PNG payloads.
(int, int)? pngPixelSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  // PNG signature is 8 bytes; the IHDR chunk length/type occupy bytes 8..15,
  // then width (16..19) and height (20..23), all big-endian u32.
  if (bytes[0] != 0x89 || bytes[1] != 0x50) return null; // \x89PNG
  final view = ByteData.sublistView(bytes);
  return (view.getUint32(16), view.getUint32(20));
}
/// One predefined cursor shape (port of OpenNOW's PREDEFINED_CURSORS):
/// the classic arrow / text / wait / crosshair / resize family, each with
/// its hotspot and a 1-bit 32x32 ICO bitmap the client renders client-side.
/// id 0 is the hidden cursor (no bitmap); unknown ids fall back to id 1.
class GfnPredefinedCursor {
  final int id;
  final String style;
  final int hotspotX;
  final int hotspotY;
  final String imageBase64;

  const GfnPredefinedCursor({
    required this.id,
    required this.style,
    required this.hotspotX,
    required this.hotspotY,
    required this.imageBase64,
  });
}

const List<GfnPredefinedCursor> predefinedCursorTable = [
  GfnPredefinedCursor(id: 0, style: 'none', hotspotX: 0, hotspotY: 0, imageBase64: ''),
  GfnPredefinedCursor(id: 1, style: 'default', hotspotX: 2, hotspotY: 1, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAAOAAAADAAAABwAAAAYAAAAOAAABDAAAAZwAAAHYAAAB4AAAAf+AAAH/AAAB/gAAAfwAAAH4AAAB8AAAAeAAAAHAAAABgAAAAQAAAAAAAAAAAAAAAAAAAA////////////////////////////////////////////5////8P///+D////h////wf//98P///OD///xh///8Af///AP///wAH//8AD///AB///wA///8Af///AP///wH///8D////B////w////8f////P////3/////////8='),
  GfnPredefinedCursor(id: 2, style: 'text', hotspotX: 8, hotspotY: 13, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfvwAAAAAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAfPwAAAAAAAAAAAAAAAAAA/////////////////////////////////////+BA///Agf///z////8/////P////z////8/////P////z////8/////P////z////8/////P////z////8/////P////z////8/////P////z///+BA///Agf////////////8='),
  GfnPredefinedCursor(id: 3, style: 'wait', hotspotX: 7, hotspotY: 12, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/8AAAzzAAAHDgAABfoAAAb2AAADbAAAAfgAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAB+AAAA/wAAAaWAAAH/gAABWoAAA//AAAP/wAAAAAAAAAAAAA//////////////////////////////////////////+AAf//gAH//4AB//+AAf//wAP//8AD///gB///8A////gf///8P////D////w////8P////D////gf///wD///4Af//8AD///AA///gAH//4AB//+AAf//gAH///////8='),
  GfnPredefinedCursor(id: 4, style: 'crosshair', hotspotX: 8, hotspotY: 8, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQAAABjAAABgMAAAQBAAAIAIAACACAABAAQAAAIAAAEABAAAgAgAAIAIAABgMAAAICAAABjAAAAFAAAAAAAAA//////////////////////////////////////////////////////////////////////////////////////4////5T///53P//+97///fff//333//79+//+AAP//v37//999///fff//53P///d3///5T////j////////8='),
  GfnPredefinedCursor(id: 5, style: 'progress', hotspotX: 2, hotspotY: 1, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD4AAAAiAAAAPgAAABwAAAYIAAAOCAAADAgAABwcAAAYNgAAOCoABDA+AAZwAAAHYAAAB4AAAAf+AAAH/AAAB/gAAAfwAAAH4AAAB8AAAAeAAAAHAAAABgAAAAQAAAAAAAAAAAAAAAAAAAA///////////////////////+A////gP///4D///+A///5wf//8OP//+Dj///h4///wcH/98OA//ODgP/xh4D/8AeA//AP///wAH//8AD///AB///wA///8Af///AP///wH///8D////B////w////8f////P////3/////////8='),
  GfnPredefinedCursor(id: 6, style: 'nwse-resize', hotspotX: 9, hotspotY: 8, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP4AAAB+AAAAPgAAAB4AAABuAAAA5gAAAcIAAEOAAABnAAAAdgAAAHgAAAB8AAAAfgAAAH8AAAAAAAAAAAAAA/////////////////////////////////////////////////////////////////////////////////wA///+AP///wD///+A////gP///wD//34A//88GP//GDz//wB+//8A////Af///wH///8A////AH///wA////////8='),
  GfnPredefinedCursor(id: 7, style: 'nesw-resize', hotspotX: 9, hotspotY: 9, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfwAAAH4AAAB8AAAAeAAAAHYAAABnAAAAQ4AAAAHCAAAA5gAAAG4AAAAeAAAAPgAAAH4AAAD+AAAAAAAAAAAAA////////////////////////////////////////////////////////////////////////////////wA///8Af///AP///wH///8B////AP///wB+//8YPP//PBj//34A////AP///4D///+A////AP///gD///wA///////8='),
  GfnPredefinedCursor(id: 8, style: 'ew-resize', hotspotX: 13, hotspotY: 8, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAEAABgBgAA4AcAAeAHgAPv98AH7/fgA+/3wAHgB4AA4AcAAGAGAAAgBAAAAAAAAAAAAAAAAAA//////////////////////////////////////////////////////////////////////////////////////+/3///P8///j/H//w/w//4P8H/8AAA/+AAAH/AAAA/4AAAf/AAAP/4P8H//D/D//4/x///P8///7/f//////8='),
  GfnPredefinedCursor(id: 9, style: 'ns-resize', hotspotX: 9, hotspotY: 12, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAADgAAAB8AAAA/gAAAf8AAAP/gAAAAAAAADgAAAA4AAAAOAAAADgAAAA4AAAAOAAAADgAAAA4AAAAAAAAA/+AAAH/AAAA/gAAAHwAAAA4AAAAEAAAAAAAAAAAAAA//////////////////////////////////////+/////H////g////wH///4A///8AH//+AA///AAH///g////4P///+D////g////4P///+D////g////4P///AAH//4AD///AB///4A////Af///4P////H////7////////8='),
  GfnPredefinedCursor(id: 10, style: 'move', hotspotX: 13, hotspotY: 12, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAABwAAAA+AAAAHAAAABwAAAAcAAAAHAAAABwAAAgACAAf3fwAP93+AB/d/AAIAAgAABwAAAAcAAAAHAAAABwAAAAcAAAAPgAAABwAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/////////////////////////////f////j////wf///4D///8Af///wf///8H///vB7//zwef/4AAD/8AAAf+AAAD/wAAB/+AAA//zwef/+8Hv///B////wf///wB///+A////wf///+P////3///////////////////////8='),
  GfnPredefinedCursor(id: 11, style: 'default', hotspotX: 2, hotspotY: 1, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAAOAAAADAAAABwAAAAYAAAAOAAABDAAAAZwAAAHYAAAB4AAAAf+AAAH/AAAB/gAAAfwAAAH4AAAB8AAAAeAAAAHAAAABgAAAAQAAAAAAAAAAAAAAAAAAAA////////////////////////////////////////////5////8P///+D////h////wf//98P///OD///xh///8Af///AP///wAH//8AD///AB///wA///8Af///AP///wH///8D////B////w////8f////P////3/////////8='),
  GfnPredefinedCursor(id: 12, style: 'pointer', hotspotX: 8, hotspotY: 3, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH+AAAB/gAAA/4AAAP/AAAH/wAAB/8AAA//gAAP/4AAH/+AADttgABzbYAAY2wAAANsAAADYAAAAwAAAAMAAAAAAAAAAAAAA//////////////////////////////////////////////////////////////////////+Af///AD///wA///4AP//+AB///AAf//wAH//4AA//+AAP//AAD//gAA//wAAP/8IAH//mAH///gD///4H///+H////z////////8='),
  GfnPredefinedCursor(id: 13, style: 'help', hotspotX: 2, hotspotY: 1, imageBase64: 'AAABAAEAICACAAEAAQAwAQAAFgAAACgAAAAgAAAAQAAAAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AAAAAAAAAAAAAAAAAAAAGAAAAAAAAAAAAAAAAAAAABgAAAAYAAAYHAAAOAYAADADAABwwwAAYMMAAODDABDAZgAZwDwAHYAAAB4AAAAf+AAAH/AAAB/gAAAfwAAAH4AAAB8AAAAeAAAAHAAAABgAAAAQAAAAAAAAAAAAAAAAAAAA/////////////+f////D////5//////////n////w///58P//8PB//+D4P//hzB//wYYf98OGH/ODhh/xh8A/8Afgf/AP8P/wAH//8AD///AB///wA///8Af///AP///wH///8D////B////w////8f////P////3/////////8='),
];

/// Looks up a predefined cursor by server id, falling back to the default
/// arrow (id 1) for unknown ids (OpenNOW: `?? cursorCache.get(1)!`).
GfnPredefinedCursor predefinedCursorFor(int id) {
  for (final cursor in predefinedCursorTable) {
    if (cursor.id == id) return cursor;
  }
  return predefinedCursorTable[1];
}

/// Decodes a 1-bit BMP-in-ICO cursor (the format OpenNOW embeds) into
/// RGBA8888 pixels, top-down. The ICO contains a BITMAPINFOHEADER with
/// height = 2x (XOR + AND mask), a 2-entry color table, a bottom-up
/// 1-bit XOR bitmap and a 1-bit AND mask (bit 1 = transparent).
/// Returns null for anything that is not a 1-bit ICO cursor.
({int width, int height, Uint8List rgba})? decodeIcoCursor(Uint8List ico) {
  if (ico.length < 6) return null;
  // ICONDIR: reserved(2) type(2) count(2); type 1 = icon.
  if (ico[0] != 0 || ico[1] != 0) return null;
  final type = ico[2] | (ico[3] << 8);
  if (type != 1) return null;
  if (ico.length < 22) return null;
  // First ICONDIRENTRY (16 bytes): width height colors reserved planes bitcount size offset.
  final width = ico[6] == 0 ? 256 : ico[6];
  final height = ico[7] == 0 ? 256 : ico[7];
  final bitCount = ico[12] | (ico[13] << 8);
  if (bitCount != 1) return null; // only the 1-bit family is ported
  final size = ico[14] | (ico[15] << 8) | (ico[16] << 16) | (ico[17] << 24);
  final offset = ico[18] | (ico[19] << 8) | (ico[20] << 16) | (ico[21] << 24);
  if (offset < 0 || offset + size > ico.length) return null;
  final bmp = ico.sublist(offset, offset + size);
  if (bmp.length < 40) return null;
  final bmpWidth = bmp[4] | (bmp[5] << 8) | (bmp[6] << 16) | (bmp[7] << 24);
  // Height includes the AND mask, so the visible image is half.
  final xorHeight = (bmp[8] | (bmp[9] << 8) | (bmp[10] << 16) | (bmp[11] << 24)) ~/ 2;
  if (bmpWidth != width || xorHeight != height) return null;
  // 1-bit color table: 2 RGBQUADs (blue green red reserved) after the header.
  const paletteOffset = 40;
  if (bmp.length < paletteOffset + 8) return null;
  final rowBytes = ((bmpWidth + 7) ~/ 8 + 3) & ~3; // 1bpp, padded to 4
  final xorStart = paletteOffset + 8;
  final andStart = xorStart + xorHeight * rowBytes;
  if (andStart + xorHeight * rowBytes > bmp.length) return null;

  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    // Bitmaps store rows bottom-up; y = height-1 is the top row.
    final row = height - 1 - y;
    for (var x = 0; x < width; x++) {
      final byteIndex = x >> 3;
      final bitMask = 0x80 >> (x & 7);
      final xorBit = (bmp[xorStart + row * rowBytes + byteIndex] & bitMask) != 0;
      final andBit = (bmp[andStart + row * rowBytes + byteIndex] & bitMask) != 0;
      // 1 = transparent (AND mask), 0 = opaque. Color from palette.
      final alpha = andBit ? 0 : 255;
      final pal = paletteOffset + (xorBit ? 4 : 0);
      final o = (y * width + x) * 4;
      rgba[o] = bmp[pal + 2]; // R
      rgba[o + 1] = bmp[pal + 1]; // G
      rgba[o + 2] = bmp[pal]; // B
      rgba[o + 3] = alpha;
    }
  }
  return (width: width, height: height, rgba: rgba);
}
