import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Retires replaced video frames without leaking or use-after-free.
///
/// A [ui.Image] that is still referenced by the most recently built layer
/// tree must outlive that frame's rasterization, so a replaced image is
/// disposed two presented frames after replacement instead of immediately.
/// Images whose decode completed too late to ever be shown (dropped by the
/// sequence check) are never referenced by any layer and can be disposed
/// right away.
class FrameRetirement {
  FrameRetirement._();

  /// Disposes [image] once the raster pipeline has drained past any frame
  /// that could still reference it.
  static void retire(ui.Image image) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        image.dispose();
      });
    });
  }
}
