// lib/core/result.dart
// A small Result type to avoid throwing for expected failures.

sealed class Result<T> {
  const Result();

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;

  Ok<T> get ok => this as Ok<T>;
  Err<T> get err => this as Err<T>;
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'Err($message, cause: $cause)';
}
