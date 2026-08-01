import 'package:gfn_core/gfn_core.dart';

/// Human-friendly error message. [SessionError] already carries a mapped
/// title + description; anything else gets its noisy prefix stripped.
String friendlyError(Object error) {
  if (error is SessionError) {
    return '${error.title}: ${error.description}';
  }
  final text = error.toString().trim();
  final stripped = text.replaceFirst(
    RegExp(
      r'^(?:Bad state|StateError|Exception|FormatException|TypeError|'
      r'HttpException|SocketException|TimeoutException|ArgumentError):\s*',
    ),
    '',
  );
  return stripped.isEmpty ? 'Unknown error' : stripped;
}

/// Short title for an error (used in snackbar headlines).
String errorTitle(Object error) {
  if (error is SessionError) return error.title;
  return 'Error';
}
