import 'dart:async';
import 'dart:isolate';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/executors/killable_isolate_executor.dart';
import 'package:vector_map_tiles/src/executors/worker_failure.dart';

String? _isolateName(Object? _) => Isolate.current.debugName;

int _fail(String message) => throw StateError(message);

int _spinUntilKilled(SendPort started) {
  started.send(null);
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < const Duration(minutes: 1)) {}
  return 0;
}

int _double(int value) => value * 2;

String _echo(String value) => value;

int _length(String value) => value.length;

int _exitWorker(Object? _) => Isolate.exit();

Future<int> _crashWorker(Object? _) {
  Timer.run(() => throw StateError('worker crashed'));
  return Completer<int>().future;
}

Future<Isolate> _failToSpawn(
  void Function(SendPort replies) entryPoint,
  SendPort replies, {
  bool paused = false,
  SendPort? onExit,
  String? debugName,
}) =>
    Future.error(IsolateSpawnException('no isolate for $debugName'));

Job<int, int> _doubleJob(int value) =>
    Job('double', _double, value, deduplicationKey: null);

Job<Object?, int> _exitJob() =>
    Job('exit', _exitWorker, null, deduplicationKey: null);

Future<KillableIsolateExecutor> _readyExecutor() async {
  final executor = KillableIsolateExecutor();
  addTearDown(executor.dispose);
  await executor.submit(_doubleJob(1));
  return executor;
}

final _workerExited = throwsA(
  isA<WorkerFailure>().having(
    (failure) => failure.message,
    'message',
    endsWith(' exited'),
  ),
);

final _spawnFailed = throwsA(
  isA<WorkerFailure>().having(
    (failure) => failure.cause,
    'cause',
    isA<IsolateSpawnException>(),
  ),
);

void main() {
  group('KillableIsolateExecutor', () {
    late List<FlutterErrorDetails> reported;

    setUp(() {
      reported = [];
      final reportError = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = reportError);
    });

    test('runs a job in its own isolate and returns the result', () async {
      final executor = KillableIsolateExecutor();
      addTearDown(executor.dispose);

      final name = await executor.submit(
        Job('name', _isolateName, null, deduplicationKey: null),
      );

      expect(name, startsWith('vectorTileWorker'));
    });

    test('a job that throws completes with the error', () async {
      final executor = KillableIsolateExecutor();
      addTearDown(executor.dispose);

      final result = executor.submit(
        Job('fail', _fail, 'broken tile', deduplicationKey: null),
      );

      await expectLater(
        result,
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'broken tile'),
        ),
      );
    });

    test(
      'dispose kills the isolate during a synchronous job',
      () async {
        final exits = ReceivePort();
        final started = ReceivePort();
        final executor = KillableIsolateExecutor(onExit: exits.sendPort);
        final result = executor.submit(
          Job('spin', _spinUntilKilled, started.sendPort,
              deduplicationKey: null),
        );
        final cancelled = expectLater(
          result,
          throwsA(isA<CancellationException>()),
        );
        await started.first;

        executor.dispose();

        expect(await exits.first, isNull);
        await cancelled;
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'dispose before the isolate is ready kills it once spawned',
      () async {
        final exits = ReceivePort();
        final executor = KillableIsolateExecutor(onExit: exits.sendPort);
        final queued = executor.submit(
          Job('double', _double, 21, deduplicationKey: null),
        );
        final cancelled = expectLater(
          queued,
          throwsA(isA<CancellationException>()),
        );

        executor.dispose();

        expect(await exits.first, isNull);
        await cancelled;
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('a failed spawn fails the queued jobs and every later one', () async {
      final executor = KillableIsolateExecutor(spawn: _failToSpawn);
      addTearDown(executor.dispose);

      final queued = executor.submit(_doubleJob(21));
      await expectLater(queued, _spawnFailed);
      final later = executor.submit(_doubleJob(21));

      await expectLater(later, _spawnFailed);
    });

    test('a failed worker reports its failure once', () async {
      final executor = KillableIsolateExecutor(spawn: _failToSpawn);
      addTearDown(executor.dispose);

      await expectLater(executor.submit(_doubleJob(1)), _spawnFailed);
      await expectLater(executor.submit(_doubleJob(2)), _spawnFailed);

      expect(
        reported.map((details) => details.exception),
        [isA<WorkerFailure>()],
      );
    });

    test('a disposed worker reports nothing', () async {
      final exits = ReceivePort();
      final executor = KillableIsolateExecutor(onExit: exits.sendPort);
      await executor.submit(_doubleJob(1));

      executor.dispose();
      await exits.first;
      await pumpEventQueue();

      expect(reported, isEmpty);
    });

    test(
      'a pool sends every job to the live worker once the other has failed',
      () async {
        var spawned = 0;
        final pool = PoolExecutor(
          concurrency: 2,
          executorFactory: () => spawned++ == 0
              ? KillableIsolateExecutor(spawn: _failToSpawn)
              : KillableIsolateExecutor(),
        );
        addTearDown(pool.dispose);
        await pumpEventQueue();

        final results = await Future.wait([
          for (var value = 1; value <= 6; value++)
            pool.submit(_doubleJob(value)),
        ]);

        expect(results, [2, 4, 6, 8, 10, 12]);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'an unexpected worker exit fails the running and queued jobs',
      () async {
        final executor = await _readyExecutor();

        final running = executor.submit(_exitJob());
        final queued = executor.submit(_doubleJob(21));

        await Future.wait([
          expectLater(running, _workerExited),
          expectLater(queued, _workerExited),
        ]);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'a worker that has exited fails new jobs at once',
      () async {
        final executor = await _readyExecutor();
        await expectLater(executor.submit(_exitJob()), _workerExited);

        final next = executor.submit(_doubleJob(21));

        await expectLater(next, _workerExited);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'a worker that dies of an uncaught error fails its job with a '
      'WorkerFailure carrying that error',
      () async {
        final executor = KillableIsolateExecutor();
        addTearDown(executor.dispose);

        final running = executor.submit(
          Job('crash', _crashWorker, null, deduplicationKey: null),
        );

        await expectLater(
          running,
          throwsA(
            isA<WorkerFailure>().having(
              (failure) => failure.cause,
              'cause',
              isA<RemoteError>().having(
                (error) => error.toString(),
                'error',
                contains('worker crashed'),
              ),
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'a reply that does not match the job type fails that job and the '
      'worker goes on',
      () async {
        final executor = await _readyExecutor();

        final text = executor.submit(
          Job('text', _echo, 'tile', deduplicationKey: 'tile'),
        );
        final length = executor.submit(
          Job('length', _length, 'tile', deduplicationKey: 'tile'),
        );
        final next = executor.submit(_doubleJob(21));
        final mismatch = expectLater(length, throwsA(isA<TypeError>()));

        expect(await text, 'tile');
        await mismatch;
        expect(await next, 42);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
