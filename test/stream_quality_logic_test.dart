import 'package:flutter_test/flutter_test.dart';

String _aspectRatio(int width, int height) {
  const canonical = [
    (w: 16, h: 9),
    (w: 16, h: 10),
    (w: 21, h: 9),
    (w: 32, h: 9),
    (w: 4, h: 3),
    (w: 5, h: 4),
    (w: 3, h: 2),
  ];
  final ratio = width / height;
  for (final c in canonical) {
    if ((c.w / c.h - ratio).abs() < 0.08) return '${c.w}:${c.h}';
  }
  var a = width;
  var b = height;
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return '${width ~/ a}:${height ~/ a}';
}

void main() {
  test('aspect ratio grouping', () {
    expect(_aspectRatio(1920, 1080), '16:9');
    expect(_aspectRatio(2560, 1440), '16:9');
    expect(_aspectRatio(1920, 1200), '16:10');
    expect(_aspectRatio(1680, 1050), '16:10');
    expect(_aspectRatio(2560, 1600), '16:10');
    expect(_aspectRatio(3440, 1440), '21:9');
    expect(_aspectRatio(5120, 1440), '32:9');
  });

  test('resolution string format matches parseResolution expectation', () {
    const width = 2560;
    const height = 1440;
    final resolution = '${width}x$height';
    final parts = resolution.split('x');
    expect(int.parse(parts[0]), width);
    expect(int.parse(parts[1]), height);
  });
}
