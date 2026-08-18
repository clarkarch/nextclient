import 'package:flutter/services.dart';

/// Flutter keyboard → GFN VK/scancode mapping — port of OpenNOW's
/// `keyboardMapping.ts` + `keyboardScancodes.ts`.
///
/// The GFN server resolves keys by VK + keyboard layout (official clients
/// send scancode 0), so the primary output is the Windows virtual-key code
/// derived from the Flutter physical key (which follows the DOM `code` naming
/// convention).

/// Maps a Flutter [KeyEvent] to the GFN protocol's (keycode, scancode) pair.
/// Returns null for keys the streamer doesn't know (IME/unknown physical keys).
({int keycode, int scancode})? mapFlutterKeyEvent(KeyEvent event) {
  // Soft-keyboard keys can arrive as simulated key events whose PHYSICAL key
  // is a vendor usage (e.g. the number row on some IMEs reports
  // 0x1100000008 — not a keyboard-page HID id), so the physical-key mapping
  // returns null even though the LOGICAL key is perfectly normal (Digit1, …).
  // Fall back to the logical key so those digits/letters still reach the game
  // instead of being silently dropped.
  var code = _domCodeFromPhysicalKey(event.physicalKey);
  code ??= _domCodeFromLogicalKey(event.logicalKey);
  if (code == null) return null;

  final vk = _defaultVirtualKeyFromCode(code);
  if (vk == null || vk == 0) return null;

  // Official GFN Zc() always sends scancode 0; the server uses layout + VK.
  return (keycode: vk, scancode: 0);
}

/// Maps a [LogicalKeyboardKey] to a DOM-style code as a fallback for
/// IME-simulated key events whose physical key carries a vendor usage.
/// Digits' logical keyId IS their US VK code (0x30..0x39); letters carry
/// lowercase ASCII ids (0x61..0x7a).
String? _domCodeFromLogicalKey(LogicalKeyboardKey key) {
  final id = key.keyId;
  if (id >= 0x30 && id <= 0x39) {
    return id == 0x30 ? 'Digit0' : 'Digit${id - 0x30}';
  }
  if (id >= 0x61 && id <= 0x7a) {
    return 'Key${String.fromCharCode(id - 0x20)}';
  }
  return null;
}

/// Per-key modifier byte (port of OpenNOW's `modifierFlags`).
/// ctrl=0x02, alt=0x04, meta=0x08, shift=0x01 (shift bit via `xb()`).
int modifierFlagsForKeyEvent(KeyEvent event) {
  var flags = 0;
  final code = _domCodeFromPhysicalKey(event.physicalKey) ?? '';
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isControlPressed && !code.startsWith('Control')) flags |= 0x02;
  if (keyboard.isAltPressed && !code.startsWith('Alt')) flags |= 0x04;
  if (keyboard.isMetaPressed && !code.startsWith('Meta')) flags |= 0x08;
  if (keyboard.isShiftPressed && !code.startsWith('Shift')) {
    flags |= 1; // shiftModifierByte
  }
  return flags;
}

/// Tracks CapsLock/NumLock/ScrollLock toggles for INPUT_LOCK_KEYS_SYNC.
/// This Flutter's `HardwareKeyboard` doesn't expose lock-key getters, so we
/// track toggles from key events exactly like the official client's `iS()`.
class LockKeyState {
  bool capsLock = false;
  bool numLock = false;
  bool scrollLock = false;

  /// Toggle the bit matching [event]'s lock key; returns true if it changed.
  bool toggleFor(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.capsLock) {
      capsLock = !capsLock;
      return true;
    }
    if (key == LogicalKeyboardKey.numLock) {
      numLock = !numLock;
      return true;
    }
    if (key == LogicalKeyboardKey.scrollLock) {
      scrollLock = !scrollLock;
      return true;
    }
    return false;
  }

  /// Lock-key bitmask for INPUT_LOCK_KEYS_SYNC (port of OpenNOW's
  /// `lockKeysStateFromEvent`): base 0x10 | caps 0x01 | 0x20 | 0x40 | num 0x02
  /// | scroll 0x04. Caps/Num/Scroll are NOT stuffed into per-key modifier
  /// bytes — they travel in this dedicated sync packet.
  int get protocolBits {
    var state = 0x10;
    if (capsLock) state |= 0x01;
    state |= 0x20;
    state |= 0x40;
    if (numLock) state |= 0x02;
    if (scrollLock) state |= 0x04;
    return state;
  }
}

/// Whether [event] is a lock-key toggle (CapsLock/NumLock/ScrollLock) that
/// should trigger an INPUT_LOCK_KEYS_SYNC packet.
bool isLockKeyEvent(KeyEvent event) {
  final key = event.logicalKey;
  return key == LogicalKeyboardKey.capsLock ||
      key == LogicalKeyboardKey.numLock ||
      key == LogicalKeyboardKey.scrollLock;
}

/// Translate a Flutter [PhysicalKeyboardKey] to the DOM-style `code` string
/// OpenNOW's tables are keyed by (e.g. "KeyA", "Digit1", "ArrowUp").
///
/// The code is derived from the key's canonical USB HID keyboard usage rather
/// than `key.debugName`: on this Flutter SDK `debugName` is only computed
/// inside an `assert()` (so it's null in release/profile builds) and, in
/// debug builds, returns spaced names like "Key A" / "Digit 1" that don't
/// match the DOM convention. `usbHidUsage` is a plain const field populated
/// in every build mode, so mapping from it works everywhere.
String? _domCodeFromPhysicalKey(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage == 0) return null;
  return _domCodeFromHidUsage(usage);
}

/// Maps a USB HID keyboard-page usage (0x07xxxxxx) to the DOM `code` string.
String? _domCodeFromHidUsage(int usage) {
  final page = usage >> 16;
  if (page != 0x07) return null; // only the keyboard page
  final id = usage & 0xffff;

  // Letters: 0x04..0x1d → KeyA..KeyZ.
  if (id >= 0x04 && id <= 0x1d) {
    return 'Key${String.fromCharCode(0x41 + id - 0x04)}';
  }
  // Digits: 0x1e..0x26 → Digit1..Digit9, 0x27 → Digit0.
  if (id >= 0x1e && id <= 0x27) {
    return id == 0x27 ? 'Digit0' : 'Digit${id - 0x1d}';
  }
  // Function row: 0x3a..0x45 → F1..F12, 0x68..0x73 → F13..F24.
  if (id >= 0x3a && id <= 0x45) return 'F${id - 0x39}';
  if (id >= 0x68 && id <= 0x73) return 'F${id - 0x5b}';
  // Keypad digits: 0x59..0x61 → Numpad1..Numpad9, 0x62 → Numpad0.
  if (id >= 0x59 && id <= 0x61) return 'Numpad${id - 0x58}';
  if (id == 0x62) return 'Numpad0';
  return _specialDomCodeByHidId[id];
}

/// HID keyboard usage id → DOM code for non-alphanumeric keys.
const Map<int, String> _specialDomCodeByHidId = {
  0x28: 'Enter',
  0x29: 'Escape',
  0x2a: 'Backspace',
  0x2b: 'Tab',
  0x2c: 'Space',
  0x2d: 'Minus',
  0x2e: 'Equal',
  0x2f: 'BracketLeft',
  0x30: 'BracketRight',
  0x31: 'Backslash',
  0x64: 'IntlBackslash',
  0x33: 'Semicolon',
  0x34: 'Quote',
  0x35: 'Backquote',
  0x36: 'Comma',
  0x37: 'Period',
  0x38: 'Slash',
  0x39: 'CapsLock',
  0x46: 'PrintScreen',
  0x47: 'ScrollLock',
  0x48: 'Pause',
  0x49: 'Insert',
  0x4a: 'Home',
  0x4b: 'PageUp',
  0x4c: 'Delete',
  0x4d: 'End',
  0x4e: 'PageDown',
  0x4f: 'ArrowRight',
  0x50: 'ArrowLeft',
  0x51: 'ArrowDown',
  0x52: 'ArrowUp',
  0x53: 'NumLock',
  0x54: 'NumpadDivide',
  0x55: 'NumpadMultiply',
  0x56: 'NumpadSubtract',
  0x57: 'NumpadAdd',
  0x58: 'NumpadEnter',
  0x63: 'NumpadDecimal',
  0x65: 'ContextMenu',
  0xda: 'NumpadClear',
  0x67: 'NumpadEqual',
  0x85: 'NumpadComma',
  0x87: 'IntlRo',
  0x89: 'IntlYen',
  0xe0: 'ControlLeft',
  0xe1: 'ShiftLeft',
  0xe2: 'AltLeft',
  0xe3: 'MetaLeft',
  0xe4: 'ControlRight',
  0xe5: 'ShiftRight',
  0xe6: 'AltRight',
  0xe7: 'MetaRight',
};

/// Port of OpenNOW's `defaultVirtualKeyFromCode()`.
int? _defaultVirtualKeyFromCode(String code) {
  if (code.startsWith('Key') && code.length == 4) {
    return code.codeUnitAt(3);
  }
  if (code.startsWith('Digit') && code.length == 6) {
    return code.codeUnitAt(5);
  }
  if (code.startsWith('F')) {
    final index = int.tryParse(code.substring(1));
    if (index != null && index >= 1 && index <= 24) {
      return 0x70 + index - 1;
    }
  }
  if (code.startsWith('Numpad') && code.length == 7) {
    final digit = int.tryParse(code.substring(6));
    if (digit != null && digit >= 0 && digit <= 9) {
      return 0x60 + digit;
    }
  }
  return _specialVirtualKeyByCode[code];
}

const Map<String, int> _specialVirtualKeyByCode = {
  'Enter': 0x0d, 'Escape': 0x1b, 'Backspace': 0x08, 'Tab': 0x09,
  'Space': 0x20, 'Minus': 0xbd, 'Equal': 0xbb,
  'BracketLeft': 0xdb, 'BracketRight': 0xdd, 'Backslash': 0xdc,
  'IntlBackslash': 0xe2, 'IntlRo': 0xc2, 'IntlYen': 0xc1,
  'Semicolon': 0xba, 'Quote': 0xde, 'Backquote': 0xc0,
  'Comma': 0xbc, 'Period': 0xbe, 'Slash': 0xbf,
  'ArrowRight': 0x27, 'ArrowLeft': 0x25, 'ArrowDown': 0x28, 'ArrowUp': 0x26,
  'ControlLeft': 0xa2, 'ShiftLeft': 0xa0, 'AltLeft': 0xa4, 'MetaLeft': 0x5b,
  'ControlRight': 0xa3, 'ShiftRight': 0xa1, 'AltRight': 0xa5, 'MetaRight': 0x5c,
  'CapsLock': 0x14, 'NumLock': 0x90, 'Insert': 0x2d, 'Delete': 0x2e,
  'Home': 0x24, 'End': 0x23, 'PageUp': 0x21, 'PageDown': 0x22,
  'PrintScreen': 0x2a, 'ScrollLock': 0x91, 'Pause': 0x13, 'ContextMenu': 0x5d,
  'OSLeft': 0x5b, 'OSRight': 0x5c,
  'NumpadClear': 0x0c, 'NumpadClearEntry': 0x0c,
  'NumpadAdd': 0x6b, 'NumpadSubtract': 0x6d, 'NumpadMultiply': 0x6a,
  'NumpadDivide': 0x6f, 'NumpadDecimal': 0x6e, 'NumpadEnter': 0x0d,
  'NumpadEqual': 0xbb, 'NumpadComma': 0xbc,
};


