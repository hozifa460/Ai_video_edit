import 'dart:developer' as dev;

enum LogLevel { debug, info, warning, error }

class AppLogger {
  static final AppLogger _instance = AppLogger._();
  factory AppLogger() => _instance;
  AppLogger._();

  bool _enabled = true;

  void disable() => _enabled = false;

  void _log(LogLevel level, String message, [Object? error, StackTrace? stack]) {
    if (!_enabled) return;
    final prefix = level.name.toUpperCase();
    final logMessage = '[$prefix] $message';
    if (error != null) {
      dev.log(logMessage, error: error, stackTrace: stack);
    } else {
      dev.log(logMessage);
    }
  }

  void d(String message) => _log(LogLevel.debug, message);
  void i(String message) => _log(LogLevel.info, message);
  void w(String message, [Object? error]) => _log(LogLevel.warning, message, error);
  void e(String message, [Object? error, StackTrace? stack]) =>
      _log(LogLevel.error, message, error, stack);
}
