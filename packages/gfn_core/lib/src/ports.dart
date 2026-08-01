abstract class TokenStorage {
  Future<Map<String, String>?> readTokens();
  Future<void> writeTokens(Map<String, String> tokens);
  Future<void> clearTokens();
}

abstract class BrowserLauncher {
  Future<void> openUrl(String url);
}

abstract class Clock {
  int nowMillis();
}

abstract class RandomSource {
  List<int> nextBytes(int count);
}