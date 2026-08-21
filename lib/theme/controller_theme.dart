import 'package:flutter/material.dart';

/// Controller visual themes — each changes the overall look (shape,
/// background, density) not just the tint. Colours are still part of it
/// but the layout feels different per theme.
enum ControllerTheme {
  neon(
    'Neon',
    Color(0xFF00D9FF),
    Color(0xFF8B5CF6),
    Color(0xFF14141F),
    shape: ControllerShape.rounded,
    density: 1.0,
    showShadows: true,
    description: 'Glowing rounded · default',
  ),
  midnight(
    'Midnight',
    Color(0xFF3A8DFF),
    Color(0xFF1E3A8A),
    Color(0xFF0A0F1E),
    shape: ControllerShape.rounded,
    density: 0.92,
    showShadows: true,
    description: 'Compact · deep blue',
  ),
  crimson(
    'Crimson',
    Color(0xFFFF3B30),
    Color(0xFFFF6B35),
    Color(0xFF1A0F0F),
    shape: ControllerShape.square,
    density: 1.08,
    showShadows: true,
    description: 'Angular · bold square',
  ),
  frost(
    'Frost',
    Color(0xFFE0F2FF),
    Color(0xFF60A5FA),
    Color(0xFF0F172A),
    shape: ControllerShape.minimal,
    density: 0.88,
    showShadows: false,
    description: 'Minimal · outline only',
  ),
  arcade(
    'Arcade',
    Color(0xFFFFD60A),
    Color(0xFFFF8C42),
    Color(0xFF1A1200),
    shape: ControllerShape.block,
    density: 1.15,
    showShadows: true,
    description: 'Huge · blocky · retro',
  ),
  stealth(
    'Stealth',
    Color(0xFF9CA3AF),
    Color(0xFF6B7280),
    Color(0x00000000),
    shape: ControllerShape.minimal,
    density: 0.95,
    showShadows: false,
    description: 'Stealth · transparent',
  ),
  cyber(
    'Cyber',
    Color(0xFFFF00FF),
    Color(0xFF00FFFF),
    Color(0xFF0F0A1A),
    shape: ControllerShape.rounded,
    density: 1.0,
    showShadows: true,
    description: 'Cyber · pink/cyan duotone',
  );

  const ControllerTheme(
    this.label,
    this.primary,
    this.secondary,
    this.baseBg, {
    required this.shape,
    required this.density,
    required this.showShadows,
    required this.description,
  });

  final String label;
  final Color primary;
  final Color secondary;
  final Color baseBg;
  final ControllerShape shape;
  final double density;
  final bool showShadows;
  final String description;

  Color get border => primary.withValues(alpha: 0.38);
  Color get glow => primary.withValues(alpha: 0.38);
  Color get dpadGlow => secondary.withValues(alpha: 0.42);
}

enum ControllerShape { rounded, square, block, minimal }
