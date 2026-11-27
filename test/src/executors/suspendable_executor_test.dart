import 'dart:io';
import 'dart:isolate';

import 'package:executor_lib/executor_lib.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/executors/killable_isolate_executor.dart';
import 'package:vector_map_tiles/src/executors/suspendable_executor.dart';

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
      'jobs waiting for a replay settle when its workers die',
      () async {
        final crashMarker = File(
          '${Directory.systemTemp.createTempSync('replay').path}/crash',
        );
        addTearDown(() => crashMarker.parent.deleteSync(recursive: true));
        final executor = SuspendableExecutor(
          () => PoolExecutor(
            concurrency: 2,
            executorFactory: KillableIsolateExecutor.new,
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
        crashMarker.createSync();
        executor.suspend();
        final waiting = executor.submit(
          Job('theme', _themeOf, 'light', deduplicationKey: null),
        );

        executor.resume();

        await expectLater(
          waiting,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              endsWith(' exited'),
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
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
