import '../errors/failures.dart' as errors;

sealed class Result<T> {
  const Result();
}

final class Success<T> extends Result<T> {
  final T value;
  const Success(this.value);
}

final class AppError<T> extends Result<T> {
  final errors.Failure error;
  const AppError(this.error);
}
