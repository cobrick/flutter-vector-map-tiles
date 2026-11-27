import 'dart:async';

import 'package:executor_lib/executor_lib.dart';

class MockPools {
  final created = <MockPoolExecutor>[];

  MockPoolExecutor get current => created.last;

  Executor create() {
    final pool = MockPoolExecutor();
    created.add(pool);
    return pool;
  }
}

class MockPoolExecutor implements Executor {
  final submitted = <MockPoolJob>[];
  var _disposed = false;

  Iterable<String> get jobNames =>
      submitted.map((submission) => submission.job.name);

  @override
  bool get disposed => _disposed;

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) {
    final submission = MockPoolJob(job);
    submitted.add(submission);
    return submission.future;
  }

  @override
  List<Future<R>> submitAll<Q, R>(Job<Q, R> job) => [submit(job)];

  @override
  void dispose() {
    _disposed = true;
    for (final submission in submitted) {
      submission.cancel();
    }
  }
}

class MockPoolJob<Q, R> {
  MockPoolJob(this.job);

  final Job<Q, R> job;
  final _completer = Completer<R>();

  Future<R> get future => _completer.future;

  void run() => _completer.complete(job.computeFunction(job.value));

  void complete(R result) => _completer.complete(result);

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.completeError(CancellationException());
    }
  }
}
