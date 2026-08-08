import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Receives physical (Bluetooth / USB) Android gamepad state from the native
/// activity bridge (`MainActivity` → `next_client/gamepad` channel) and hands
/// it to the stream surface. Fully automatic — no UI — with XInput-style
/// button flags and normalized (-1..1) stick/trigger axes.
class PhysicalGamepad {
  static const MethodChannel _channel = MethodChannel('next_client/gamepad');

  final void Function(
    int buttons,
    double lx,
    double ly,
    double rx,
    double ry,
    double lt,
    double rt,
  )
  _onState;

  PhysicalGamepad(this._onState) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(_handle);
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'state') return null;
    final m = call.arguments;
    if (m is! Map) return null;
    _onState(
      (m['buttons'] as num?)?.toInt() ?? 0,
      (m['lx'] as num?)?.toDouble() ?? 0,
      (m['ly'] as num?)?.toDouble() ?? 0,
      (m['rx'] as num?)?.toDouble() ?? 0,
      (m['ry'] as num?)?.toDouble() ?? 0,
      (m['lt'] as num?)?.toDouble() ?? 0,
      (m['rt'] as num?)?.toDouble() ?? 0,
    );
    return null;
  }

  void dispose() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(null);
  }
}
