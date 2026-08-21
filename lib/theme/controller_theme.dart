import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shape language for the controller's controls — how round/angular every
/// body is, independent of its colours.
enum ControllerShape { rounded, square, block, pill }

/// Surface material used to paint every control body. Each material changes
/// HOW a control is drawn (gradients, shadows, borders), not just its tint.
enum ControllerMaterial { neumorphic, glass, metal, pixel, flat, ghost }

/// How the face-button glyphs are drawn.
enum FaceLabelStyle { coloredLetters, whiteLetters, playstationSymbols }

/// Full visual specification for the virtual gamepad: palette, shape
/// language, surface material and glyph style in one immutable object.
/// Curated presets live in [ControllerThemes].
class ControllerTheme {
  final String id;
  final String label;
  final String description;

  /// Accent / pressed-glow colour.
  final Color primary;

  /// Secondary accent (D-pad glow, home ring).
  final Color secondary;

  /// Control body colour (face buttons, sticks, D-pad).
  final Color baseBg;

  /// Chrome body colour (menu / shoulder / trigger buttons).
  final Color panelBg;

  /// Gradient partner for [baseBg] — usually darker, for depth.
  final Color bodyColor;

  /// Label colour on chrome buttons.
  final Color inkColor;

  /// Face-button glyph colours.
  final Color faceA;
  final Color faceB;
  final Color faceX;
  final Color faceY;

  final FaceLabelStyle faceLabels;
  final ControllerShape shape;
  final ControllerMaterial material;
  final bool showShadows;

  /// Component-size multiplier baked into the preset (0.85–1.2).
  final double density;

  const ControllerTheme({
    required this.id,
    required this.label,
    required this.description,
    required this.primary,
    required this.secondary,
    required this.baseBg,
    required this.panelBg,
    required this.bodyColor,
    required this.inkColor,
    this.faceA = Colors.white,
    this.faceB = Colors.white,
    this.faceX = Colors.white,
    this.faceY = Colors.white,
    this.faceLabels = FaceLabelStyle.coloredLetters,
    this.shape = ControllerShape.rounded,
    this.material = ControllerMaterial.neumorphic,
    this.showShadows = true,
    this.density = 1.0,
  });

  Color get glow => primary.withValues(alpha: 0.38);
  Color get dpadGlow => secondary.withValues(alpha: 0.42);

  /// Returns a copy of this theme with the given fields replaced. Used for
  /// runtime overrides (e.g. the visual-effects toggle forcing shadows off)
  /// without mutating the const presets.
  ControllerTheme copyWith({
    bool? showShadows,
    double? density,
  }) {
    return ControllerTheme(
      id: id,
      label: label,
      description: description,
      primary: primary,
      secondary: secondary,
      baseBg: baseBg,
      panelBg: panelBg,
      bodyColor: bodyColor,
      inkColor: inkColor,
      faceA: faceA,
      faceB: faceB,
      faceX: faceX,
      faceY: faceY,
      faceLabels: faceLabels,
      shape: shape,
      material: material,
      showShadows: showShadows ?? this.showShadows,
      density: density ?? this.density,
    );
  }

  Color faceColor(FaceGlyph glyph) => switch (glyph) {
        FaceGlyph.a => faceA,
        FaceGlyph.b => faceB,
        FaceGlyph.x => faceX,
        FaceGlyph.y => faceY,
      };

  /// Corner radius for a control whose natural size is [size], following the
  /// preset's shape language.
  double cornerFor(double size) => switch (shape) {
        ControllerShape.rounded => size * 0.28,
        ControllerShape.square => size * 0.10,
        ControllerShape.block => 2,
        ControllerShape.pill => size * 0.5,
      };
}

/// The four face buttons, theme-agnostic so painters can ask for colours by
/// glyph without importing widget enums.
enum FaceGlyph { a, b, x, y }

/// Shared painting helpers so every control (face buttons, sticks, D-pad)
/// renders its body consistently for the active material.
extension ControllerThemePaint on ControllerTheme {
  /// Paints a circular control body (face buttons, stick base/knob).
  /// [press] is the animated press amount (0..1); the body scales down to
  /// 90% at full press, matching the chrome buttons' AnimatedScale.
  void paintControlCircle(
    Canvas canvas,
    Offset center,
    double radius, {
    double press = 0,
    Color? fill,
  }) {
    final scale = 1 - 0.10 * press.clamp(0.0, 1.0);
    final rect = Rect.fromCircle(center: center, radius: radius * scale);
    _paintControl(
      canvas,
      Path()..addOval(rect),
      rect,
      radius * scale,
      press: press,
      fill: fill,
      circular: true,
    );
  }

  /// Paints a rectangular control body (D-pad arms, shoulders, triggers).
  /// [press] is the animated press amount (0..1) — the body scales down to
  /// 90% about its own center at full press.
  void paintControlRRect(
    Canvas canvas,
    RRect rrect, {
    double press = 0,
    Color? fill,
  }) {
    final scale = 1 - 0.10 * press.clamp(0.0, 1.0);
    final outer = rrect.outerRect;
    final scaled = Rect.fromCenter(
      center: outer.center,
      width: outer.width * scale,
      height: outer.height * scale,
    );
    final scaledRRect = RRect.fromRectAndRadius(scaled, rrect.blRadius);
    _paintControl(
      canvas,
      Path()..addRRect(scaledRRect),
      scaled,
      rrect.blRadiusX,
      press: press,
      fill: fill,
    );
  }

  void _paintControl(
    Canvas canvas,
    Path path,
    Rect bounds,
    double corner, {
    required double press,
    Color? fill,
    bool circular = false,
  }) {
    final accent = fill ?? primary;
    final shortest = bounds.shortestSide;
    final t = press.clamp(0.0, 1.0);

    // Pressed glow sits under the body and fades in with the animation.
    if (t > 0 && showShadows && material != ControllerMaterial.pixel) {
      canvas.drawPath(
        path,
        Paint()
          ..color = accent.withValues(alpha: 0.40 * t)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    switch (material) {
      case ControllerMaterial.neumorphic:
        if (showShadows) {
          canvas.drawPath(
            path.shift(Offset(0, ui.lerpDouble(3, 1, t)!)),
            Paint()
              ..color = Colors.black
                  .withValues(alpha: ui.lerpDouble(0.35, 0.50, t)!)
              ..maskFilter = MaskFilter.blur(
                BlurStyle.normal,
                ui.lerpDouble(6, 4, t)!,
              ),
          );
        }
        final bodyPaint = Paint();
        if (showShadows) {
          bodyPaint.shader = RadialGradient(
            colors: [
              Color.lerp(baseBg, accent.withValues(alpha: 0.95), t)!,
              Color.lerp(bodyColor, accent.withValues(alpha: 0.70), t)!,
            ],
            center: const Alignment(-0.3, -0.3),
            radius: 1.2,
          ).createShader(bounds);
        } else {
          // Effects off: flat fill, no gradient depth.
          bodyPaint.color =
              Color.lerp(baseBg, accent.withValues(alpha: 0.85), t)!;
        }
        canvas.drawPath(path, bodyPaint);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ui.lerpDouble(1.5, 2, t)!
            ..color = Color.lerp(
              Colors.white.withValues(alpha: showShadows ? 0.12 : 0.05),
              accent.withValues(alpha: 0.85),
              t,
            )!,
        );

      case ControllerMaterial.glass:
        canvas.drawPath(
          path,
          Paint()
            ..color = (fill ?? baseBg)
                .withValues(alpha: ui.lerpDouble(0.32, 0.55, t)!),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ui.lerpDouble(1.2, 1.5, t)!
            ..color = accent.withValues(alpha: ui.lerpDouble(0.45, 0.90, t)!),
        );

      case ControllerMaterial.metal:
        if (showShadows) {
          canvas.drawPath(
            path.shift(const Offset(0, 3)),
            Paint()
              ..color = Colors.black
                  .withValues(alpha: ui.lerpDouble(0.35, 0.5, t)!)
              ..maskFilter =
                  const MaskFilter.blur(BlurStyle.normal, 5),
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                  Color.lerp(bodyColor, Colors.white, 0.16)!,
                  Color.lerp(bodyColor, accent, 0.35)!,
                  t,
                )!,
                Color.lerp(
                  Color.lerp(baseBg, Colors.black, 0.22)!,
                  Color.lerp(panelBg, accent, 0.20)!,
                  t,
                )!,
              ],
            ).createShader(bounds),
        );
        // Inner specular ring reads as brushed metal.
        if (showShadows) {
          canvas.save();
          canvas.clipPath(path);
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1.0, shortest * 0.06)
              ..color = Colors.white.withValues(alpha: 0.10),
          );
          canvas.restore();
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ui.lerpDouble(1.2, 2, t)!
            ..color = Color.lerp(
              Colors.black.withValues(alpha: 0.45),
              accent.withValues(alpha: 0.9),
              t,
            )!,
        );

      case ControllerMaterial.pixel:
        canvas.drawPath(
          path,
          Paint()..color = Color.lerp(baseBg, accent, t)!,
        );
        // Stepped top-left highlight, clipped to the body — hard edges only.
        canvas.save();
        canvas.clipPath(path);
        canvas.drawRect(
          Rect.fromLTWH(
            bounds.left + shortest * 0.10,
            bounds.top + shortest * 0.10,
            shortest * 0.34,
            shortest * 0.34,
          ),
          Paint()..color = Colors.white.withValues(alpha: 0.12),
        );
        canvas.restore();
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Color.lerp(
              inkColor.withValues(alpha: 0.5),
              Colors.white.withValues(alpha: 0.9),
              t,
            )!,
        );

      case ControllerMaterial.flat:
        canvas.drawPath(
          path,
          Paint()..color = Color.lerp(baseBg, accent, t)!,
        );
        if (t < 1) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color =
                  Colors.white.withValues(alpha: 0.06 * (1 - t)),
          );
        }

      case ControllerMaterial.ghost:
        if (t > 0) {
          canvas.drawPath(
            path,
            Paint()..color = accent.withValues(alpha: 0.22 * t),
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = Color.lerp(
              inkColor.withValues(alpha: 0.70),
              accent,
              t,
            )!,
        );
    }
  }

  /// BoxDecoration mirroring [_paintControl] for widget-based chrome buttons
  /// (menu / shoulder / trigger) that use AnimatedContainer.
  BoxDecoration chromeDecoration({
    required bool pressed,
    required double radius,
    Color? accent,
  }) {
    final a = accent ?? primary;
    final shape = BorderRadius.circular(radius);

    switch (material) {
      case ControllerMaterial.neumorphic:
        return BoxDecoration(
          color: pressed ? Color.lerp(panelBg, a, 0.30)! : panelBg,
          borderRadius: shape,
          border: Border.all(
            color: pressed
                ? a.withValues(alpha: 0.8)
                : Colors.white.withValues(alpha: 0.10),
            width: pressed ? 1.5 : 1,
          ),
          boxShadow: showShadows
              ? [
                  BoxShadow(
                    color:
                        Colors.black.withValues(alpha: pressed ? 0.25 : 0.4),
                    blurRadius: pressed ? 3 : 6,
                    offset: Offset(0, pressed ? 1 : 3),
                  ),
                  if (pressed)
                    BoxShadow(
                      color: a.withValues(alpha: 0.35),
                      blurRadius: 8,
                    ),
                ]
              : const [],
        );
      case ControllerMaterial.glass:
        return BoxDecoration(
          color: pressed
              ? Color.lerp(panelBg, a, 0.35)!.withValues(alpha: 0.70)
              : panelBg.withValues(alpha: 0.38),
          borderRadius: shape,
          border: Border.all(
            color: a.withValues(alpha: pressed ? 0.9 : 0.45),
            width: pressed ? 1.5 : 1,
          ),
        );
      case ControllerMaterial.metal:
        return BoxDecoration(
          gradient: showShadows
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: pressed
                      ? [
                          Color.lerp(bodyColor, a, 0.35)!,
                          Color.lerp(panelBg, a, 0.20)!,
                        ]
                      : [
                          Color.lerp(bodyColor, Colors.white, 0.14)!,
                          Color.lerp(panelBg, Colors.black, 0.20)!,
                        ],
                )
              : null,
          color: showShadows
              ? null
              : pressed
                  ? Color.lerp(panelBg, a, 0.30)
                  : panelBg,
          borderRadius: shape,
          border: Border.all(
            color: pressed
                ? a.withValues(alpha: 0.9)
                : Colors.black.withValues(alpha: 0.45),
            width: pressed ? 1.5 : 1,
          ),
          boxShadow: [
            if (showShadows)
              BoxShadow(
                color:
                    Colors.black.withValues(alpha: pressed ? 0.25 : 0.35),
                blurRadius: pressed ? 3 : 5,
                offset: Offset(0, pressed ? 1 : 2),
              ),
            if (pressed)
              BoxShadow(
                color: a.withValues(alpha: 0.40),
                blurRadius: 10,
              ),
          ],
        );
      case ControllerMaterial.pixel:
        return BoxDecoration(
          color: pressed ? a : panelBg,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(
            color: pressed
                ? Colors.white.withValues(alpha: 0.9)
                : inkColor.withValues(alpha: 0.5),
            width: 2,
          ),
        );
      case ControllerMaterial.flat:
        return BoxDecoration(
          color: pressed ? a : panelBg,
          borderRadius: shape,
        );
      case ControllerMaterial.ghost:
        return BoxDecoration(
          color: pressed ? a.withValues(alpha: 0.22) : Colors.transparent,
          borderRadius: shape,
          border: Border.all(
            color: pressed ? a : inkColor.withValues(alpha: 0.7),
            width: 1.4,
          ),
        );
    }
  }

  /// Label colour on a chrome button for the current press state.
  Color chromeInk({required bool pressed}) {
    if (pressed) return Colors.white;
    return inkColor.withValues(alpha: 0.9);
  }
}

/// Curated controller looks. Each preset combines palette + shape + material
/// + glyph style; users pick one in the stream settings sidebar.
class ControllerThemes {
  ControllerThemes._();

  static const neon = ControllerTheme(
    id: 'neon',
    label: 'Neon',
    description: 'Glowing cyan/violet · default',
    primary: Color(0xFF00D9FF),
    secondary: Color(0xFF8B5CF6),
    baseBg: Color(0xFF2A2A3E),
    panelBg: Color(0xFF12121C),
    bodyColor: Color(0xFF14141F),
    inkColor: Color(0xFFF2F7FF),
    faceA: Color(0xFF34D399),
    faceB: Color(0xFFF87171),
    faceX: Color(0xFF00D9FF),
    faceY: Color(0xFF8B5CF6),
  );

  static const midnight = ControllerTheme(
    id: 'midnight',
    label: 'Midnight',
    description: 'Compact · deep blue',
    primary: Color(0xFF3A8DFF),
    secondary: Color(0xFF1E3A8A),
    baseBg: Color(0xFF16223B),
    panelBg: Color(0xFF0A0F1E),
    bodyColor: Color(0xFF0C1526),
    inkColor: Color(0xFFCFE1FF),
    faceA: Color(0xFF3A8DFF),
    faceB: Color(0xFF6D9EFF),
    faceX: Color(0xFF9EC1FF),
    faceY: Color(0xFF2E5FBF),
    density: 0.92,
  );

  static const crimson = ControllerTheme(
    id: 'crimson',
    label: 'Crimson',
    description: 'Angular · bold square',
    primary: Color(0xFFFF3B30),
    secondary: Color(0xFFFF6B35),
    baseBg: Color(0xFF331512),
    panelBg: Color(0xFF1A0F0F),
    bodyColor: Color(0xFF241010),
    inkColor: Color(0xFFFFD9D4),
    faceA: Color(0xFFFF6B35),
    faceB: Color(0xFFFF3B30),
    faceX: Color(0xFFFF8C69),
    faceY: Color(0xFFFFC042),
    shape: ControllerShape.square,
    density: 1.08,
  );

  static const frost = ControllerTheme(
    id: 'frost',
    label: 'Frost',
    description: 'Minimal · icy outline',
    primary: Color(0xFFE0F2FF),
    secondary: Color(0xFF60A5FA),
    baseBg: Color(0xFF152238),
    panelBg: Color(0xFF0F172A),
    bodyColor: Color(0xFF0F172A),
    inkColor: Color(0xFFE0F2FF),
    faceLabels: FaceLabelStyle.whiteLetters,
    shape: ControllerShape.pill,
    material: ControllerMaterial.ghost,
    showShadows: false,
    density: 0.88,
  );

  static const cyber = ControllerTheme(
    id: 'cyber',
    label: 'Cyber',
    description: 'Pink/cyan duotone',
    primary: Color(0xFFFF00FF),
    secondary: Color(0xFF00FFFF),
    baseBg: Color(0xFF1C0F26),
    panelBg: Color(0xFF0F0A1A),
    bodyColor: Color(0xFF14081C),
    inkColor: Color(0xFFFFE9FF),
    faceA: Color(0xFF00FFFF),
    faceB: Color(0xFFFF00FF),
    faceX: Color(0xFF00FFFF),
    faceY: Color(0xFFFF00FF),
  );

  static const xbox = ControllerTheme(
    id: 'xbox',
    label: 'Xbox Carbon',
    description: 'Carbon metal · classic ABXY',
    primary: Color(0xFF107C10),
    secondary: Color(0xFF0078D7),
    baseBg: Color(0xFF232323),
    panelBg: Color(0xFF151515),
    bodyColor: Color(0xFF1B1B1B),
    inkColor: Color(0xFFF5F5F5),
    faceA: Color(0xFF3FA834),
    faceB: Color(0xFFE4311B),
    faceX: Color(0xFF0078D7),
    faceY: Color(0xFFFFB900),
    material: ControllerMaterial.metal,
  );

  static const playstation = ControllerTheme(
    id: 'playstation',
    label: 'PlayStation',
    description: 'Symbols △ ○ × □',
    primary: Color(0xFF0070D1),
    secondary: Color(0xFF9CA3AF),
    baseBg: Color(0xFF2B2B33),
    panelBg: Color(0xFF1B1B22),
    bodyColor: Color(0xFF222229),
    inkColor: Color(0xFFECECF2),
    faceA: Color(0xFF5FA8E8),
    faceB: Color(0xFFF05A5A),
    faceX: Color(0xFFE86EA4),
    faceY: Color(0xFF3EC9AE),
    faceLabels: FaceLabelStyle.playstationSymbols,
  );

  static const joycon = ControllerTheme(
    id: 'joycon',
    label: 'Joy-Con',
    description: 'Light plastic · neon red/blue',
    primary: Color(0xFFFF3C28),
    secondary: Color(0xFF00C3E3),
    baseBg: Color(0xFFE8E9EB),
    panelBg: Color(0xFFDEDFE3),
    bodyColor: Color(0xFFF4F5F7),
    inkColor: Color(0xFF2B2B2E),
    faceA: Color(0xFF2B2B2E),
    faceB: Color(0xFF2B2B2E),
    faceX: Color(0xFF2B2B2E),
    faceY: Color(0xFF2B2B2E),
    material: ControllerMaterial.flat,
  );

  static const retro = ControllerTheme(
    id: 'retro',
    label: 'Retro Arcade',
    description: 'Blocky pixel · amber CRT',
    primary: Color(0xFFFFD60A),
    secondary: Color(0xFFFF8C42),
    baseBg: Color(0xFF2E230A),
    panelBg: Color(0xFF1A1200),
    bodyColor: Color(0xFF241B07),
    inkColor: Color(0xFFFFD60A),
    faceA: Color(0xFFFFD60A),
    faceB: Color(0xFFFF8C42),
    faceX: Color(0xFFFFD60A),
    faceY: Color(0xFFFF8C42),
    shape: ControllerShape.block,
    material: ControllerMaterial.pixel,
    showShadows: false,
    density: 1.15,
  );

  static const glass = ControllerTheme(
    id: 'glass',
    label: 'Glass',
    description: 'Frosted translucent',
    primary: Color(0xFF7DD3FC),
    secondary: Color(0xFFC4B5FD),
    baseBg: Color(0xFF1E293B),
    panelBg: Color(0xFF172033),
    bodyColor: Color(0xFF27364F),
    inkColor: Color(0xFFF0F9FF),
    faceA: Color(0xFF7DD3FC),
    faceB: Color(0xFFF0ABFC),
    faceX: Color(0xFF86EFAC),
    faceY: Color(0xFFFDE68A),
    material: ControllerMaterial.glass,
    showShadows: false,
  );

  static const carbon = ControllerTheme(
    id: 'carbon',
    label: 'Carbon',
    description: 'Graphite metal · orange',
    primary: Color(0xFFFB923C),
    secondary: Color(0xFF94A3B8),
    baseBg: Color(0xFF33383F),
    panelBg: Color(0xFF202429),
    bodyColor: Color(0xFF444A52),
    inkColor: Color(0xFFE2E8F0),
    faceA: Color(0xFFFB923C),
    faceB: Color(0xFFE2E8F0),
    faceX: Color(0xFF94A3B8),
    faceY: Color(0xFFFBBF24),
    shape: ControllerShape.square,
    material: ControllerMaterial.metal,
    density: 1.02,
  );

  static const stealth = ControllerTheme(
    id: 'stealth',
    label: 'Stealth',
    description: 'Monochrome · transparent',
    primary: Color(0xFF9CA3AF),
    secondary: Color(0xFF6B7280),
    baseBg: Color(0xFF1F2937),
    panelBg: Color(0xFF111827),
    bodyColor: Color(0xFF1F2937),
    inkColor: Color(0xFFD1D5DB),
    faceA: Color(0xFFD1D5DB),
    faceB: Color(0xFFD1D5DB),
    faceX: Color(0xFFD1D5DB),
    faceY: Color(0xFFD1D5DB),
    faceLabels: FaceLabelStyle.whiteLetters,
    shape: ControllerShape.pill,
    material: ControllerMaterial.ghost,
    showShadows: false,
    density: 0.95,
  );

  /// Every preset in picker order.
  static const all = [
    neon,
    midnight,
    crimson,
    frost,
    cyber,
    xbox,
    playstation,
    joycon,
    retro,
    glass,
    carbon,
    stealth,
  ];

  /// Looks up a preset by persisted id, falling back to [neon].
  static ControllerTheme byId(String? id) =>
      all.where((t) => t.id == id).firstOrNull ?? neon;
}
