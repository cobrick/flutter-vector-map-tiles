import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_map_tiles/src/executors/lifecycle_aware_executor.dart';

class MockLifecycleAwareExecutor implements LifecycleAwareExecutor {
  final calls = <String>[];
  var _suspended = false;
  var _disposed = false;

  @override
  bool get isSuspended => _suspended;

  @override
  bool get disposed => _disposed;

  @override
  void suspend() {
    calls.add('suspend');
    _suspended = true;
  }

  @override
  void resume() {
    calls.add('resume');
    _suspended = false;
  }

  @override
  void dispose() {
    calls.add('dispose');
    _disposed = true;
  }

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) => Completer<R>().future;

  @override
  List<Future<R>> submitAll<Q, R>(Job<Q, R> job) => [submit(job)];
}
