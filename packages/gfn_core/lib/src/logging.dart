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
      return '${m.group(1)} [REDACTED]';
    });
    inner.log(level, category, safe);
  }
}

class RingBufferLogSink implements LogSink {
  final int maxEntries;
  final List<LogEntry> _entries = [];
  int _nextIndex = 0;

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
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      message: message,
    );
    if (_entries.length < maxEntries) {
      _entries.add(entry);
    } else {
      _entries[_nextIndex] = entry;
      _nextIndex = (_nextIndex + 1) % maxEntries;
    }
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