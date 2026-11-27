import 'dart:async';

import 'package:executor_lib/executor_lib.dart';

import 'lifecycle_aware_executor.dart';
import 'worker_failure.dart';

class SuspendableExecutor implements LifecycleAwareExecutor {
  SuspendableExecutor(this._createPool);

  final Executor Function() _createPool;
  final _setupJobs = <_PendingJob>[];
  final _running = <_PendingJob>{};
  final _waiting = <_PendingJob>[];
  Executor? _pool;
  var _suspended = false;
  var _replaying = false;
  var _disposed = false;

  @override
  bool get isSuspended => _suspended;

  @override
  bool get disposed => _disposed;

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) {
    if (_disposed) {
      return Future.error(CancellationException());
    }
    final pending = _PendingJob(job, onEveryWorker: false);
    if (_suspended || _replaying) {
      _wait(pending);
    } else {
      _run(pending, _livePool());
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
    if (_disposed || _suspended) {
      return;
    }
    _suspended = true;
    _replaying = false;
    final pool = _pool;
    if (pool == null) {
      return;
    }
    _pool = null;
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
    if (_disposed || !_suspended) {
      return;
    }
    _suspended = false;
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
    if (!_suspended) {
      setup.runOn(_livePool());
    }
    return setup;
  }

  Executor _livePool() => _pool ??= _createPool();

  void _run(_PendingJob job, Executor pool) {
    _running.add(job);
    job.runOn(pool).then((outcome) {
      if (outcome == _Outcome.superseded || !_running.remove(job)) {
        return;
      }
      if (outcome == _Outcome.workerFailed) {
        _wait(job);
      }
    });
  }

  void _wait(_PendingJob job) {
    _dropCancelledWaiting();
    _waiting.add(job);
  }

  void _dropCancelledWaiting() => _waiting.removeWhere((job) {
        if (!job.isCancelled) {
          return false;
        }
        job.cancel();
        return true;
      });

  void _runWaiting(Executor pool) {
    if (!identical(pool, _pool)) {
      return;
    }
    _replaying = false;
    _dropCancelledWaiting();
    final waiting = [..._waiting];
    _waiting.clear();
    for (final job in waiting) {
      _run(job, pool);
    }
  }
}

enum _Outcome { settled, workerFailed, superseded }

class _PendingJob<Q, R> {
  _PendingJob(this.job, {required this.onEveryWorker});

  final Job<Q, R> job;
  final bool onEveryWorker;
  final _completer = Completer<R>();
  Object? _attempt;

  Future<R> get future => _completer.future;

  bool get isCompleted => _completer.isCompleted;

  bool get isCancelled => job.isCancelled;

  Future<_Outcome> runOn(Executor pool) {
    final attempt = _attempt = Object();
    return _submitTo(pool).then(
      (result) => _settle(attempt, () => _completer.complete(result)),
      onError: (Object error, StackTrace stackTrace) => error is WorkerFailure
          ? _awaitNextPool(attempt)
          : _settle(attempt, () => _completer.completeError(error, stackTrace)),
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
        () => onEveryWorker ? _submitToEveryWorker(pool) : pool.submit(job),
      );

  Future<R> _submitToEveryWorker(Executor pool) async {
    final failures = <WorkerFailure>[];
    final results = await Future.wait([
      for (final result in pool.submitAll(job))
        result.then<(R,)?>(
          (value) => (value,),
          onError: (Object error, StackTrace stackTrace) {
            if (error case final WorkerFailure failure) {
              failures.add(failure);
              return null;
            }
            Error.throwWithStackTrace(error, stackTrace);
          },
        ),
    ]);
    if (results.nonNulls.firstOrNull case (final value,)) {
      return value;
    }
    throw failures.first;
  }

  _Outcome _settle(Object attempt, void Function() complete) {
    if (!_isCurrent(attempt)) {
      return _Outcome.superseded;
    }
    complete();
    return _Outcome.settled;
  }

  _Outcome _awaitNextPool(Object attempt) {
    if (!_isCurrent(attempt)) {
      return _Outcome.superseded;
    }
    _attempt = null;
    return _Outcome.workerFailed;
  }

  bool _isCurrent(Object attempt) =>
      identical(attempt, _attempt) && !isCompleted;
}
