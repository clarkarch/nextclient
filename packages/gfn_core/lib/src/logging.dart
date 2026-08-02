import 'dart:io';

enum LogLevel { debug, info, warn, error }

abstract class LogSink {
  void log(LogLevel level, String category, String message);
}

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String category;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
  });
}

class TokenRedactingLogger implements LogSink {
  final LogSink inner;

  TokenRedactingLogger(this.inner);

  static final _tokenPattern =
      RegExp(r'(GFNJWT|Bearer)\s+\S+', caseSensitive: false);

  @override
  void log(LogLevel level, String category, String message) {
    final safe = message.replaceAllMapped(_tokenPattern, (m) {
      return '${m.group(1)} [TOKEN REDACTED]';
    });
    inner.log(level, category, safe);
  }
}

/// Scrubs sensitive values from a log message so entries are safe to copy and
/// share. Each replacement is an explicit `[... REDACTED]` marker — never a
/// hash or placeholder that an LLM (or human) could mistake for a real value.
///
/// This is the app-wide safety net: every message written through
/// [RingBufferLogSink.log] passes through here, so even a future log call that
/// forgets to redact at the call site can't leak a token, IP, or identifier.
String redactLogMessage(String message) {
  var result = message;

  // Auth tokens: replace the whole `Scheme <credential>` pair.
  result = result.replaceAllMapped(
    RegExp(r'(GFNJWT|Bearer)\s+\S+', caseSensitive: false),
    (_) => '[TOKEN REDACTED]',
  );

  // IPv4 addresses (server IPs, ICE candidates can embed them).
  result = result.replaceAllMapped(
    RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'),
    (_) => '[IP REDACTED]',
  );

  // UUIDs (session IDs, device IDs, client IDs, sub-session IDs).
  result = result.replaceAllMapped(
    RegExp(
        r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'),
    (_) => '[UUID REDACTED]',
  );

  // Long opaque hex strings (NVIDIA uses these for session/auth identifiers).
  result = result.replaceAllMapped(
    RegExp(r'\b[0-9a-fA-F]{24,}\b'),
    (_) => '[HEX ID REDACTED]',
  );

  return result;
}

class RingBufferLogSink implements LogSink {
  final int maxEntries;
  final List<LogEntry> _entries = [];
  int _nextIndex = 0;

  /// When false, log entries are dropped (verbose logging disabled). The
  /// buffer itself is preserved so re-enabling resumes from existing state.
  bool enabled = true;

  RingBufferLogSink({this.maxEntries = 500});

  List<LogEntry> get entries {
    if (_entries.length < maxEntries) return List.unmodifiable(_entries);
    return [
      for (int i = _nextIndex; i < maxEntries; i++) _entries[i],
      for (int i = 0; i < _nextIndex; i++) _entries[i],
    ];
  }

  @override
  void log(LogLevel level, String category, String message) {
    if (!enabled) return;
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      message: redactLogMessage(message),
    );
    if (_entries.length < maxEntries) {
      _entries.add(entry);
    } else {
      _entries[_nextIndex] = entry;
      _nextIndex = (_nextIndex + 1) % maxEntries;
    }
  }
}

/// Formats a log entry as a single human-readable terminal/file line.
String formatLogLine(LogEntry entry) {
  final t = entry.timestamp;
  final time =
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
  return '[$time] [${entry.level.name.toUpperCase()}] [${entry.category}] '
      '${entry.message}';
}

/// Writes log lines to the process standard output. On desktop this is the
/// terminal the app was launched from.
class TerminalLogSink implements LogSink {
  /// The writer receiving each formatted line. Defaults to stdout.
  final void Function(String line) writer;

  TerminalLogSink({void Function(String line)? writer})
      : writer = writer ?? (stdout.writeln);

  @override
  void log(LogLevel level, String category, String message) {
    writer(formatLogLine(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        category: category,
        message: redactLogMessage(message),
      ),
    ));
  }
}

/// A [LogSink] that fans a single log call out to multiple sinks. Every child
/// receives the same redacted message, so the terminal, disk file, and in-memory
/// buffer stay in sync. Honors an `enabled` flag that stops all children.
class CompositeLogSink implements LogSink {
  final List<LogSink> _sinks;

  /// When false, no child sink receives anything (verbose logging disabled).
  bool enabled = true;

  CompositeLogSink(Iterable<LogSink> sinks) : _sinks = List.unmodifiable(sinks);

  /// Applies the shared `enabled` flag to every child that supports it, so the
  /// in-memory buffer (and its Logs viewer) matches the other sinks.
  void setEnabledForAll(bool value) {
    enabled = value;
    for (final sink in _sinks) {
      if (sink is RingBufferLogSink) sink.enabled = value;
    }
  }

  /// The most recent entries from the in-memory [RingBufferLogSink] child, if
  /// any (used by the Logs viewer). Empty if no ring buffer is attached.
  List<LogEntry> get entries {
    for (final sink in _sinks) {
      if (sink is RingBufferLogSink) return sink.entries;
    }
    return const [];
  }

  @override
  void log(LogLevel level, String category, String message) {
    if (!enabled) return;
    for (final sink in _sinks) {
      sink.log(level, category, message);
    }
  }
}

/// Writes log lines to a file on disk (append-only).
///
/// Writes are **synchronous and flushed every line**, so every entry is durable
/// on disk the moment it's logged — the log survives a hard app crash or a
/// `kill -9`. Logging is allowed to be slightly slower than other I/O, so we
/// skip buffering entirely for crash survivability.
class FileLogSink implements LogSink {
  final RandomAccessFile _raf;
  bool _disposed = false;

  /// Creates a sink writing to [file], creating it (and any parent
  /// directories) on first use.
  factory FileLogSink(File file) {
    file.parent.createSync(recursive: true);
    return FileLogSink._(file.openSync(mode: FileMode.append));
  }

  FileLogSink._(this._raf);

  @override
  void log(LogLevel level, String category, String message) {
    if (_disposed) return;
    final line = formatLogLine(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        category: category,
        message: redactLogMessage(message),
      ),
    );
    try {
      _raf.writeStringSync('$line\n');
      _raf.flushSync();
    } catch (e) {
      // Disk I/O failing shouldn't take down the app; the in-memory and
      // terminal sinks still have the entry.
    }
  }

  /// Flushes any pending writes (no-op; every write is already synchronous).
  Future<void> flush() async => _raf.flushSync();

  /// Flushes and closes the underlying file handle.
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _raf.flushSync();
      _raf.closeSync();
    } catch (_) {}
  }
}

typedef LoggerFactory = LogSink Function(String category);

LoggerFactory createLoggerFactory(LogSink root) {
  return (String category) {
    final categorySink = _CategoryLogSink(root, category);
    return TokenRedactingLogger(categorySink);
  };
}

class _CategoryLogSink implements LogSink {
  final LogSink root;
  final String category;

  _CategoryLogSink(this.root, this.category);

  @override
  void log(LogLevel level, String subcategory, String message) {
    root.log(level, category, message);
  }
}