import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_map_tiles/src/cache/cache.dart';
import 'package:vector_map_tiles/src/executors/suspendable_executor.dart';
import 'package:vector_map_tiles/src/loader/no_op_tile_loader.dart';
import 'package:vector_map_tiles/src/model/map_properties.dart';
import 'package:vector_map_tiles/src/widgets/abstract_map_layer_state.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../mocks/mock_lifecycle_aware_executor.dart';
import '../mocks/mock_pool_executor.dart';

final _mapProperties = MapProperties(
  tileProviders: const TileProviders({}),
  theme: ProvidedThemes.lightTheme(),
  tileOffset: TileOffset.DEFAULT,
  concurrency: 0,
  cacheProperties: const CacheProperties(
    fileCacheTtl: Duration.zero,
    fileCacheMaximumSizeInBytes: 0,
    cacheFolder: null,
  ),
);

class _Layer extends AbstractMapLayer {
  _Layer(this.executor)
      : super(
          mapProperties: _mapProperties,
          tileLoaderFactory: (properties, executor, themeRepo) =>
              const NoOpTileLoader(),
        );

  final Executor executor;

  @override
  State<_Layer> createState() => _LayerState();
}

class _LayerState extends AbstractMapLayerState<_Layer> {
  @override
  Executor createExecutor() => widget.executor;

  @override
  Widget build(BuildContext context) => const SizedBox();
}

const _lifecycleFromForeground = [
  AppLifecycleState.resumed,
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

void _moveAppTo(WidgetTester tester, AppLifecycleState target) {
  final current = tester.binding.lifecycleState ?? target;
  var step = _lifecycleFromForeground.indexOf(current);
  final end = _lifecycleFromForeground.indexOf(target);
  while (step != end) {
    step += step < end ? 1 : -1;
    tester.binding.handleAppLifecycleStateChanged(
      _lifecycleFromForeground[step],
    );
  }
  tester.binding.handleAppLifecycleStateChanged(target);
}

Future<void> _pumpWhileFramesAreDisabled(
  WidgetTester tester,
  Widget widget,
) async {
  await tester.pumpWidget(widget);
  tester.binding.scheduleForcedFrame();
  await tester.pump();
}

void main() {
  group('AbstractMapLayerState', () {
    testWidgets('suspends the workers when the app becomes inactive',
        (tester) async {
      _moveAppTo(tester, AppLifecycleState.resumed);
      final executor = MockLifecycleAwareExecutor();
      await tester.pumpWidget(_Layer(executor));

      _moveAppTo(tester, AppLifecycleState.inactive);

      expect(executor.isSuspended, isTrue);
      _moveAppTo(tester, AppLifecycleState.resumed);
    });

    testWidgets('keeps the workers suspended while the app is hidden or paused',
        (tester) async {
      _moveAppTo(tester, AppLifecycleState.resumed);
      final executor = MockLifecycleAwareExecutor();
      await tester.pumpWidget(_Layer(executor));

      _moveAppTo(tester, AppLifecycleState.hidden);
      expect(executor.isSuspended, isTrue);
      _moveAppTo(tester, AppLifecycleState.paused);
      expect(executor.isSuspended, isTrue);
      _moveAppTo(tester, AppLifecycleState.inactive);
      expect(executor.isSuspended, isTrue);

      _moveAppTo(tester, AppLifecycleState.resumed);
    });

    testWidgets('resumes the workers when the app is resumed', (tester) async {
      _moveAppTo(tester, AppLifecycleState.resumed);
      final executor = MockLifecycleAwareExecutor();
      await tester.pumpWidget(_Layer(executor));
      _moveAppTo(tester, AppLifecycleState.paused);

      _moveAppTo(tester, AppLifecycleState.resumed);

      expect(executor.isSuspended, isFalse);
      expect(executor.calls.last, 'resume');
    });

    testWidgets(
        'disposes the lifecycle listener and the executor with the layer',
        (tester) async {
      _moveAppTo(tester, AppLifecycleState.resumed);
      final executor = MockLifecycleAwareExecutor();
      await tester.pumpWidget(_Layer(executor));

      await tester.pumpWidget(const SizedBox());
      _moveAppTo(tester, AppLifecycleState.inactive);

      expect(executor.disposed, isTrue);
      expect(executor.calls.last, 'dispose');
      _moveAppTo(tester, AppLifecycleState.resumed);
    });

    testWidgets('a layer built while the app is paused starts suspended',
        (tester) async {
      _moveAppTo(tester, AppLifecycleState.paused);
      final pools = MockPools();
      final executor = SuspendableExecutor(pools.create);

      await _pumpWhileFramesAreDisabled(tester, _Layer(executor));

      expect(executor.isSuspended, isTrue);
      expect(pools.created, isEmpty);
      _moveAppTo(tester, AppLifecycleState.resumed);
      expect(executor.isSuspended, isFalse);
      expect(pools.created, hasLength(1));
    });
  });
}
