import 'dart:async';
import 'dart:isolate';

import 'package:executor_lib/executor_lib.dart';

typedef IsolateSpawner = Future<Isolate> Function(
  void Function(SendPort replies) entryPoint,
  SendPort replies, {
  bool paused,
  SendPort? onExit,
  String? debugName,
});

class KillableIsolateExecutor extends ExecutorDelegate {
  KillableIsolateExecutor({
    SendPort? onExit,
    IsolateSpawner spawn = Isolate.spawn,
  }) {
    _replies.listen(_onReply);
    _start(spawn, onExit);
  }

  static var _spawnedWorkers = 0;

  final _name = 'vectorTileWorker${++_spawnedWorkers}';
  final _replies = ReceivePort();
  final _jobs = <int, _WorkerJob>{};
  final _queue = <_WorkerJob>[];
  _WorkerJob? _running;
  SendPort? _requests;
  Isolate? _isolate;
  RemoteError? _uncaughtError;
  (Object, StackTrace)? _failure;
  var _nextKey = 0;
  var _disposed = false;

  @override
  bool get disposed => _disposed;

  @override
  int get outstanding => _jobs.length;

  @override
  bool hasJobWithDeduplicationKey(Job job) =>
      job.deduplicationKey != null &&
      _jobs.values.any(
        (queued) => queued.job.deduplicationKey == job.deduplicationKey,
      );

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) {
    if (_disposed) {
      return Future.error(CancellationException());
    }
    if (_failure case (final error, final stackTrace)) {
      return Future.error(error, stackTrace);
    }
    final queued = _WorkerJob(_nextKey++, job);
    _jobs[queued.key] = queued;
    _queue.add(queued);
    _sendNext();
    return queued.future;
  }

  @override
  List<Future<R>> submitAll<Q, R>(Job<Q, R> job) => [submit(job)];

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stop((job) => job.cancel());
  }

  Future<void> _start(IsolateSpawner spawn, SendPort? onExit) async {
    try {
      final isolate = await spawn(
        _serveJobs,
        _replies.sendPort,
        paused: true,
        onExit: onExit,
        debugName: _name,
      );
      _isolate = isolate;
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      isolate
        ..addOnExitListener(_replies.sendPort)
        ..addErrorListener(_replies.sendPort)
        ..resume(isolate.pauseCapability!);
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  void _onReply(Object? reply) {
    if (_disposed || _failure != null) {
      return;
    }
    switch (reply) {
      case null:
        _failOnExit();
        return;
      case [final String error, final String? stackTrace]:
        _uncaughtError = RemoteError(error, stackTrace ?? '');
      case final SendPort requests:
        _requests = requests;
      case _JobResult(:final key, :final value):
        _running = null;
        if (_jobs.remove(key) case final job?) {
          job.complete(value);
          _completeDuplicates(job, value);
        }
      case _JobFailure(:final key, :final error, :final stackTrace):
        _running = null;
        _jobs.remove(key)?.fail(error, stackTrace);
    }
    _sendNext();
  }

  void _failOnExit() {
    if (_uncaughtError case final error?) {
      _fail(error, error.stackTrace);
    } else {
      _fail(StateError('$_name exited'), StackTrace.current);
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_disposed || _failure != null) {
      return;
    }
    _failure = (error, stackTrace);
    _stop((job) => job.fail(error, stackTrace));
  }

  void _stop(void Function(_WorkerJob job) settle) {
    _isolate?.kill(priority: Isolate.immediate);
    _replies.close();
    for (final job in _jobs.values) {
      settle(job);
    }
    _jobs.clear();
    _queue.clear();
    _running = null;
  }

  void _sendNext() {
    final requests = _requests;
    if (requests == null || _running != null) {
      return;
    }
    _dropCancelled();
    if (_queue.isEmpty) {
      return;
    }
    final next = _running = _queue.removeLast();
    try {
      requests.send(next.request);
    } catch (error, stackTrace) {
      _running = null;
      _jobs.remove(next.key);
      next.fail(error, stackTrace);
      _sendNext();
    }
  }

  void _dropCancelled() {
    _queue.removeWhere((queued) {
      if (!queued.job.isCancelled) {
        return false;
      }
      _jobs.remove(queued.key);
      queued.cancel();
      return true;
    });
  }

  void _completeDuplicates(_WorkerJob done, Object? value) {
    final deduplicationKey = done.job.deduplicationKey;
    if (deduplicationKey == null) {
      return;
    }
    _queue.removeWhere((queued) {
      if (queued.job.isCancelled ||
          queued.job.deduplicationKey != deduplicationKey) {
        return false;
      }
      _jobs.remove(queued.key);
      queued.complete(value);
      return true;
    });
  }
}

class _WorkerJob<Q, R> {
  _WorkerJob(this.key, this.job);

  final int key;
  final Job<Q, R> job;
  final _completer = Completer<dynamic>();

  Future<R> get future => _completer.future.then(_asResult);

  _JobRequest<Q, R> get request =>
      _JobRequest(key, job.computeFunction, job.value);

  void complete(Object? value) => _completer.complete(value);

  void fail(Object error, StackTrace stackTrace) =>
      _completer.completeError(error, stackTrace);

  void cancel() => _completer.completeError(CancellationException());

  R _asResult(dynamic value) => value;
}

class _JobRequest<Q, R> {
  _JobRequest(this.key, this.compute, this.value);

  final int key;
  final FutureOr<R> Function(Q value) compute;
  final Q value;

  void runAndReply(SendPort replies) {
    Future.sync(() => compute(value))
        .then((result) => replies.send(_JobResult(key, result)))
        .onError<Object>(
          (error, stackTrace) =>
              replies.send(_JobFailure(key, error, stackTrace)),
        );
  }
}

class _JobResult {
  const _JobResult(this.key, this.value);

  final int key;
  final dynamic value;
}

class _JobFailure {
  const _JobFailure(this.key, this.error, this.stackTrace);

  final int key;
  final Object error;
  final StackTrace stackTrace;
}

void _serveJobs(SendPort replies) {
  final requests = RawReceivePort((Object? request) {
    if (request case final _JobRequest job) {
      job.runAndReply(replies);
    }
  });
  replies.send(requests.sendPort);
}
