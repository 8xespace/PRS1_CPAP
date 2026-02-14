// lib/core/logging.dart

import 'dart:developer' as dev;

enum LogLevel { debug, info, warn, error }

class Log {
  static LogLevel level = LogLevel.info;

  static void d(String message, {String tag = 'CPAP', Object? error, StackTrace? st}) {
    if (level.index <= LogLevel.debug.index) {
      dev.log(message, name: tag, error: error, stackTrace: st);
    }
  }

  static void i(String message, {String tag = 'CPAP', Object? error, StackTrace? st}) {
    if (level.index <= LogLevel.info.index) {
      dev.log(message, name: tag, error: error, stackTrace: st);
    }
  }

  static void w(String message, {String tag = 'CPAP', Object? error, StackTrace? st}) {
    if (level.index <= LogLevel.warn.index) {
      dev.log('WARN: $message', name: tag, error: error, stackTrace: st);
    }
  }

  static void e(String message, {String tag = 'CPAP', Object? error, StackTrace? st}) {
    if (level.index <= LogLevel.error.index) {
      dev.log('ERROR: $message', name: tag, error: error, stackTrace: st);
    }
  }
}
