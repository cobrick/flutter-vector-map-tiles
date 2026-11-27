class WorkerFailure implements Exception {
  const WorkerFailure(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => switch (cause) {
        null => 'WorkerFailure: $message',
        final cause => 'WorkerFailure: $message: $cause',
      };
}
