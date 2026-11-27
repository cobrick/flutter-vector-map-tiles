import 'dart:async';

import 'package:executor_lib/executor_lib.dart';

import 'lifecycle_aware_executor.dart';

class SuspendableExecutor implements LifecycleAwareExecutor {
  SuspendableExecutor(this._createPool) : _pool = _createPool();

  final Executor Function() _createPool;
  final _setupJobs = <_PendingJob>[];
  final _running = <_PendingJob>{};
  final _waiting = <_PendingJob>[];
  Executor? _pool;
  var _replaying = false;
  var _disposed = false;

  @override
  bool get isSuspended => _pool == null;

  @override
  bool get disposed => _disposed;

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) {
    if (_disposed) {
      return Future.error(CancellationException());
    }
    final pending = _PendingJob(job, onEveryWorker: false);
    final pool = _pool;
    if (pool == null || _replaying) {
      _waiting.add(pending);
    } else {
      _run(pending, pool);
    }
    return pending.future;
  }

  @override
  List<Future<R>> submitAll<Q, R>(Job<Q, R> job) {
    if (_disposed) {
      return [Future.error(CancellationException())];
    }
    final setup = _seenSetupJob(job) ?? _addSetupJob(job);
    return [setup.future];
  }

  @override
  void suspend() {
    final pool = _pool;
    if (_disposed || pool == null) {
      return;
    }
    _pool = null;
    _replaying = false;
    final interrupted = _running.where((job) => !job.isCompleted).toList();
    _running.clear();
    for (final job in [..._setupJobs, ...interrupted]) {
      job.interrupt();
    }
    _waiting.insertAll(0, interrupted);
    pool.dispose();
  }

  @override
  void resume() {
    if (_disposed || _pool != null) {
      return;
    }
    final pool = _pool = _createPool();
    _replaying = true;
    Future.wait([for (final setup in _setupJobs) setup.runOn(pool)])
        .then((_) => _runWaiting(pool));
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final job in [..._setupJobs, ..._running, ..._waiting]) {
      job.cancel();
    }
    _setupJobs.clear();
    _running.clear();
    _waiting.clear();
    _pool?.dispose();
    _pool = null;
  }

  _PendingJob<Q, R>? _seenSetupJob<Q, R>(Job<Q, R> job) {
    final deduplicationKey = job.deduplicationKey;
    if (deduplicationKey == null) {
      return null;
    }
    return _setupJobs
        .whereType<_PendingJob<Q, R>>()
        .where((setup) => setup.job.deduplicationKey == deduplicationKey)
        .firstOrNull;
  }

  _PendingJob<Q, R> _addSetupJob<Q, R>(Job<Q, R> job) {
    final setup = _PendingJob(job, onEveryWorker: true);
    _setupJobs.add(setup);
    if (_pool case final pool?) {
      setup.runOn(pool);
    }
    return setup;
  }

  void _run(_PendingJob job, Executor pool) {
    _running.add(job);
    job.runOn(pool).then((settled) {
      if (settled) {
        _running.remove(job);
      }
    });
  }

  void _runWaiting(Executor pool) {
    if (!identical(pool, _pool)) {
      return;
    }
    _replaying = false;
    final waiting = [..._waiting];
    _waiting.clear();
    for (final job in waiting) {
      if (job.isCancelled) {
        job.cancel();
      } else {
        _run(job, pool);
      }
    }
  }
}

class _PendingJob<Q, R> {
  _PendingJob(this.job, {required this.onEveryWorker});

  final Job<Q, R> job;
  final bool onEveryWorker;
  final _completer = Completer<R>();
  Object? _attempt;

  Future<R> get future => _completer.future;

  bool get isCompleted => _completer.isCompleted;

  bool get isCancelled => job.isCancelled;

  Future<bool> runOn(Executor pool) {
    final attempt = _attempt = Object();
    return _submitTo(pool).then(
      (result) => _settle(attempt, () => _completer.complete(result)),
      onError: (Object error, StackTrace stackTrace) =>
          _settle(attempt, () => _completer.completeError(error, stackTrace)),
    );
  }

  void interrupt() => _attempt = null;

  void cancel() {
    _attempt = null;
    if (!isCompleted) {
      _completer.completeError(CancellationException());
    }
  }

  Future<R> _submitTo(Executor pool) => Future.sync(
        () => onEveryWorker
            ? Future.wait(pool.submitAll(job)).then((results) => results.first)
            : pool.submit(job),
      );

  bool _settle(Object attempt, void Function() complete) {
    if (!identical(attempt, _attempt) || isCompleted) {
      return false;
    }
    complete();
    return true;
  }
}
