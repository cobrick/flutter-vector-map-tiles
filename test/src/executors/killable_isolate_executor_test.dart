import 'dart:isolate';

import 'package:executor_lib/executor_lib.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/executors/killable_isolate_executor.dart';

String? _isolateName(Object? _) => Isolate.current.debugName;

int _fail(String message) => throw StateError(message);

int _spinUntilKilled(SendPort started) {
  started.send(null);
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < const Duration(minutes: 1)) {}
  return 0;
}

int _double(int value) => value * 2;

void main() {
  group('KillableIsolateExecutor', () {
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
  });
}
