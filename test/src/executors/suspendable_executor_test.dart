import 'dart:io';
import 'dart:isolate';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/executors/killable_isolate_executor.dart';
import 'package:vector_map_tiles/src/executors/suspendable_executor.dart';
import 'package:vector_map_tiles/src/executors/worker_failure.dart';

import '../mocks/mock_pool_executor.dart';

int _double(int value) => value * 2;

String _echo(String value) => value;

final _themeById = <String, String>{};

void _setUpTheme(String themeId) => _themeById[themeId] = 'theme $themeId';

void _setUpThemeUnlessMarked(String crashMarkerPath) {
  if (File(crashMarkerPath).existsSync()) {
    Isolate.exit();
  }
  _setUpTheme('light');
}

String? _themeOf(String themeId) => _themeById[themeId];

Job<int, int> _tileJob(int value, {bool Function()? cancelled}) =>
    Job('tile', _double, value, cancelled: cancelled, deduplicationKey: null);

Job<String, String> _setupJob(String themeId) =>
    Job('setup', _echo, themeId, deduplicationKey: 'setup-$themeId');

void main() {
  group('SuspendableExecutor', () {
    test('a job submitted while suspended runs after resume', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create)..suspend();

      final result = executor.submit(_tileJob(7));
      await pumpEventQueue();
      expect(pools.created, isEmpty);

      executor.resume();
      await pumpEventQueue();
      pools.current.submitted.single.run();

      expect(await result, 14);
    });

    test(
      'a job in flight at suspend runs again on the new pool and its future '
      'gets that result',
      () async {
        final pools = MockPools();
        final executor = SuspendableExecutor(pools.create);
        final result = executor.submit(_tileJob(7));
        final firstPool = pools.current;
        expect(firstPool.jobNames, ['tile']);

        executor
          ..suspend()
          ..resume();
        await pumpEventQueue();
        pools.current.submitted.single.complete(42);

        expect(firstPool.disposed, isTrue);
        expect(await result, 42);
      },
    );

    test('setup jobs are replayed before queued jobs', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final setup = executor.submitAll(_setupJob('light'));
      pools.current.submitted.single.run();
      await Future.wait(setup);
      executor.suspend();
      final result = executor.submit(_tileJob(7));

      executor.resume();
      await pumpEventQueue();
      expect(pools.current.jobNames, ['setup']);
      pools.current.submitted.single.run();
      await pumpEventQueue();

      expect(pools.current.jobNames, ['setup', 'tile']);
      pools.current.submitted.last.run();
      expect(await result, 14);
    });

    test(
      'a job waiting through an interrupted replay runs once on the next pool '
      'and its future gets that result',
      () async {
        final pools = MockPools();
        final executor = SuspendableExecutor(pools.create);
        final setup = executor.submitAll(_setupJob('light'));
        pools.current.submitted.single.run();
        await Future.wait(setup);
        executor.suspend();
        final result = executor.submit(_tileJob(7));
        executor.resume();
        await pumpEventQueue();

        executor.suspend();
        await pumpEventQueue();
        executor.resume();
        await pumpEventQueue();
        pools.current.submitted.single.run();
        await pumpEventQueue();

        expect(pools.created, hasLength(3));
        expect(pools.created[1].jobNames, ['setup']);
        expect(pools.current.jobNames, ['setup', 'tile']);
        pools.current.submitted.last.complete(42);
        expect(await result, 42);
      },
    );

    test('a job submitted while the replay runs waits until it settles',
        () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final setup = executor.submitAll(_setupJob('light'));
      pools.current.submitted.single.run();
      await Future.wait(setup);
      executor
        ..suspend()
        ..resume();
      await pumpEventQueue();

      final result = executor.submit(_tileJob(7));
      await pumpEventQueue();
      expect(pools.current.jobNames, ['setup']);
      pools.current.submitted.single.run();
      await pumpEventQueue();

      expect(pools.current.jobNames, ['setup', 'tile']);
      pools.current.submitted.last.run();
      expect(await result, 14);
    });

    test('a submitAll in flight at suspend completes after the replay',
        () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final setup = executor.submitAll(_setupJob('light')).single;

      executor
        ..suspend()
        ..resume();
      await pumpEventQueue();
      pools.current.submitted.single.complete('light, replayed');

      expect(pools.created.first.disposed, isTrue);
      expect(await setup, 'light, replayed');
    });

    test('a job whose worker fails runs again on the next pool', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final result = executor.submit(_tileJob(7));
      pools.current.submitted.single
          .fail(const WorkerFailure('vectorTileWorker1 exited'));
      await pumpEventQueue();

      executor
        ..suspend()
        ..resume();
      await pumpEventQueue();
      pools.current.submitted.single.run();

      expect(pools.created.first.jobNames, ['tile']);
      expect(await result, 14);
    });

    test(
      'a job that waits for the next pool drops the waiting jobs that were '
      'cancelled',
      () async {
        final pools = MockPools();
        final executor = SuspendableExecutor(pools.create);
        var leftTheView = false;
        final gone = executor.submit(_tileJob(1, cancelled: () => leftTheView));
        final dropped = expectLater(
          gone,
          throwsA(isA<CancellationException>()),
        );
        final visible = executor.submit(_tileJob(2));
        const workerExited = WorkerFailure('vectorTileWorker1 exited');
        pools.current.submitted.first.fail(workerExited);
        await pumpEventQueue();
        leftTheView = true;

        pools.current.submitted.last.fail(workerExited);
        await dropped;

        executor
          ..suspend()
          ..resume();
        await pumpEventQueue();
        expect(pools.current.jobNames, ['tile']);
        pools.current.submitted.single.run();
        expect(await visible, 4);
      },
    );

    test('a job that fails on a live worker fails its caller', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final result = executor.submit(_tileJob(7));

      pools.current.submitted.single.fail(StateError('broken tile'));

      await expectLater(result, throwsA(isA<StateError>()));
    });

    test('a setup counts as done once a live worker has run it', () async {
      final pools = MockPools(workersPerPool: 2);
      final executor = SuspendableExecutor(pools.create);
      final setup = executor.submitAll(_setupJob('light')).single;

      pools.current.submitted.first
          .fail(const WorkerFailure('vectorTileWorker1 failed to spawn'));
      pools.current.submitted.last.run();

      expect(await setup, 'light');
    });

    test('a setup that fails with its own error on a worker fails', () async {
      final pools = MockPools(workersPerPool: 2);
      final executor = SuspendableExecutor(pools.create);
      final setup = executor.submitAll(_setupJob('light')).single;

      pools.current.submitted.first.run();
      pools.current.submitted.last.fail(StateError('broken theme'));

      await expectLater(setup, throwsA(isA<StateError>()));
    });

    test('a setup no worker could run runs again on the next pool', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final setup = executor.submitAll(_setupJob('light')).single;
      pools.current.submitted.single
          .fail(const WorkerFailure('vectorTileWorker1 exited'));
      await pumpEventQueue();

      executor
        ..suspend()
        ..resume();
      await pumpEventQueue();
      pools.current.submitted.single.run();

      expect(await setup, 'light');
    });

    test('dispose cancels queued jobs', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create)..suspend();
      final result = executor.submit(_tileJob(7));

      executor.dispose();

      await expectLater(result, throwsA(isA<CancellationException>()));
    });

    test('dispose cancels running jobs and disposes the pool', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final result = executor.submit(_tileJob(7));

      executor.dispose();

      expect(pools.current.disposed, isTrue);
      await expectLater(result, throwsA(isA<CancellationException>()));
    });

    test('cancelled jobs are dropped on resume', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create)..suspend();
      var cancelled = false;
      final result = executor.submit(_tileJob(7, cancelled: () => cancelled));
      final dropped = expectLater(
        result,
        throwsA(isA<CancellationException>()),
      );
      cancelled = true;

      executor.resume();
      await dropped;

      expect(pools.current.submitted, isEmpty);
    });

    test('suspend and resume twice change nothing', () async {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      final result = executor.submit(_tileJob(7));

      executor
        ..suspend()
        ..suspend();
      expect(executor.isSuspended, isTrue);
      executor
        ..resume()
        ..resume();
      await pumpEventQueue();

      expect(executor.isSuspended, isFalse);
      expect(pools.created, hasLength(2));
      expect(pools.current.jobNames, ['tile']);
      pools.current.submitted.single.run();
      expect(await result, 14);
    });

    test(
      'suspend kills every worker and the new workers get the setup again',
      () async {
        final exits = ReceivePort();
        addTearDown(exits.close);
        final executor = SuspendableExecutor(
          () => PoolExecutor(
            concurrency: 2,
            executorFactory: () =>
                KillableIsolateExecutor(onExit: exits.sendPort),
          ),
        );
        addTearDown(executor.dispose);
        await Future.wait(
          executor.submitAll(
            Job('setup', _setUpTheme, 'light', deduplicationKey: 'light'),
          ),
        );
        final exited = exits.take(2).toList();

        executor.suspend();
        expect(await exited, hasLength(2));
        executor.resume();
        final themes = await Future.wait([
          for (var worker = 0; worker < 2; worker++)
            executor.submit(
              Job('theme', _themeOf, 'light', deduplicationKey: null),
            ),
        ]);

        expect(themes, ['theme light', 'theme light']);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'jobs waiting for a replay run on the next pool when its workers die',
      () async {
        final crashMarker = File(
          '${Directory.systemTemp.createTempSync('replay').path}/crash',
        );
        addTearDown(() => crashMarker.parent.deleteSync(recursive: true));
        final reported = <FlutterErrorDetails>[];
        final reportError = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = reportError);
        final exits = ReceivePort();
        addTearDown(exits.close);
        final executor = SuspendableExecutor(
          () => PoolExecutor(
            concurrency: 2,
            executorFactory: () =>
                KillableIsolateExecutor(onExit: exits.sendPort),
          ),
        );
        addTearDown(executor.dispose);
        await Future.wait(
          executor.submitAll(
            Job(
              'setup',
              _setUpThemeUnlessMarked,
              crashMarker.path,
              deduplicationKey: 'light',
            ),
          ),
        );
        final killedThenCrashed = exits.take(4).toList();
        crashMarker.createSync();
        executor.suspend();
        final waiting = executor.submit(
          Job('theme', _themeOf, 'light', deduplicationKey: null),
        );
        executor.resume();
        await killedThenCrashed;
        await pumpEventQueue();

        crashMarker.deleteSync();
        executor
          ..suspend()
          ..resume();

        expect(await waiting, 'theme light');
        expect(reported, hasLength(2));
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test('creates no pool until a job or a resume needs one', () {
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);
      expect(pools.created, isEmpty);

      executor
        ..suspend()
        ..submitAll(_setupJob('light'))
        ..submit(_tileJob(7));
      expect(pools.created, isEmpty);
      executor.resume();

      expect(pools.created, hasLength(1));
    });
  });
}
