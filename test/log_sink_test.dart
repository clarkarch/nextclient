import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gfn_core/gfn_core.dart';

void main() {
  test('FileLogSink writes redacted lines to disk', () async {
    final dir = Directory.systemTemp.createTempSync('log_test');
    final file = File('${dir.path}/app.log');
    final sink = FileLogSink(file);

    sink.log(LogLevel.info, 'app', 'Bearer abc123.def end');
    sink.log(LogLevel.info, 'session', 'Session launched (550e8400-e29b-41d4-a716-446655440000)');
    await sink.flush();
    await sink.close();

    final contents = file.readAsStringSync();
    expect(contents, contains('[TOKEN REDACTED]'));
    expect(contents, contains('[UUID REDACTED]'));
    expect(contents, isNot(contains('abc123.def')));
    expect(contents, isNot(contains('550e8400-e29b-41d4-a716-446655440000')));

    dir.deleteSync(recursive: true);
  });

  test('CompositeLogSink fans out and honors enabled', () {
    final ring = RingBufferLogSink(maxEntries: 50);
    final lines = <String>[];
    final terminal = TerminalLogSink(writer: lines.add);
    final composite = CompositeLogSink([ring, terminal]);

    composite.log(LogLevel.info, 'app', 'GFNJWT secret-token here');
    expect(ring.entries, hasLength(1));
    expect(lines, hasLength(1));
    expect(lines.single, contains('[TOKEN REDACTED]'));
    expect(ring.entries.single.message, contains('[TOKEN REDACTED]'));

    composite.setEnabledForAll(false);
    composite.log(LogLevel.info, 'app', 'should be dropped');
    expect(ring.entries, hasLength(1));
    expect(lines, hasLength(1));
  });
}
