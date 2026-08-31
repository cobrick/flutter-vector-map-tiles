import 'dart:async';
import 'dart:isolate';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../loader/caching_tile_loader.dart';
import '../loader/theme_repo.dart';
import '../model/map_properties.dart';
import '../model/tile_data_model.dart';
import 'abstract_map_layer_state.dart';

class MapLayer extends AbstractMapLayer {
  const MapLayer({super.key, required super.mapProperties})
      : super(tileLoaderFactory: createCachingTileLoader);

  @override
  State<StatefulWidget> createState() => MapLayerState();
}

class MapLayerState extends AbstractMapLayerState<MapLayer> {
  // Not `final`: didUpdateWidget replaces it when the theme changes, and a
  // second assignment to a `late final` throws LateInitializationError.
  late TilesRenderer tilesRenderer;
  var _ready = false;
  List<String> _previousTileKeys = [];

  @override
  void initState() {
    super.initState();
    tilesRenderer = TilesRenderer(widget.mapProperties.theme);
    TilesRenderer.initialize.then(_initialized);
  }

  @override
  void dispose() {
    // Own resources first, framework last.
    tilesRenderer.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MapLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mapProperties.theme != widget.mapProperties.theme) {
      tilesRenderer.dispose();
      tilesRenderer = TilesRenderer(widget.mapProperties.theme);
      super.resetState();
    }
  }

  @override
  Future<void> preRender(TileDataModel tile) {
    return super.preRender(tile).then((_) async {
      // The tile can scroll out of view (and be disposed by MapTiles) while it
      // was loading or is being prepared. Abort at each step so a fast
      // multi-level zoom doesn't spend atlas/isolate/GPU work on tiles that are
      // no longer visible.
      if (tile.disposed) return;
      final tileset = tile.tileset ?? Tileset({});
      final tileID = tile.tile.key();
      final jobArguments =
          (widget.mapProperties.theme.id, zoom, tileset, tileID);

      await tilesRenderer.preRenderUi(zoom, tileset, tileID);
      if (tile.disposed) return;
      await executor
          .submit(Job(
        "pre-render",
        _preRender(),
        jobArguments,
        deduplicationKey:
            "pre-render:${widget.mapProperties.theme.id}-${widget.mapProperties.theme.version}-$zoom-${tile.tile.key()}",
      ))
          .then((renderData) {
        if (tile.disposed) return;
        try {
          tile.renderData ??= renderData.materialize().asUint8List();
        } catch (_) {}
      });
    });
  }

  TransferableTypedData Function((String, double, Tileset, String) args)
      _preRender() {
    final preRenderer = tilesRenderer.getPreRenderer();
    return ((String, double, Tileset, String) args) {
      final theme = ThemeRepo.themeById[args.$1]!;
      return TransferableTypedData.fromList(
          [preRenderer.call(theme, args.$2, args.$3, args.$4)]);
    };
  }

  @override
  Widget build(BuildContext context) {
    updateTiles(context);
    if (!_ready) {
      return Container();
    }
    final tileModels = mapTiles.tileModels
        .where((it) => it.isDisplayReady)
        .toList(growable: false);
    final uiTiles =
        tileModels.map((it) => it.toUiModel()).toList(growable: false);

    final currentTileKeys = uiTiles.map((it) => it.tileId.key()).toList();
    if (!_tilesEqual(currentTileKeys, _previousTileKeys)) {
      _previousTileKeys = currentTileKeys;
      onTilesChanged();
    }

    tilesRenderer.update(
        zoom, uiTiles, mapTiles.tileModels.map((it) => it.tile.key()));

    return CustomPaint(
      key: Key(
        'mapTileLayer_${widget.mapProperties.theme.id}_${widget.mapProperties.theme.version}',
      ),
      painter: MapTilesPainter(widget.mapProperties, tilesRenderer, rotation),
      isComplex: true,
    );
  }

  bool _tilesEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setA = a.toSet();
    final setB = b.toSet();
    return setA.length == setB.length && setA.containsAll(setB);
  }

  FutureOr _initialized(void value) {
    if (!mounted) return null;

    // `TilesRenderer.initialize` is static and completes once per process, so
    // every layer mounted after the first resolves this future immediately —
    // in the same microtask drain as its own initState. Calling setState
    // there marks the element dirty while an ancestor (FlutterMap's
    // LayoutBuilder) is still building, which trips "Tried to build dirty
    // widget in the wrong build scope". Only that case needs deferring; the
    // common one can flip synchronously.
    //
    // `build` renders nothing until `_ready`, so a deferral that never runs
    // leaves a blank layer. addPostFrameCallback does not itself request a
    // frame, hence the explicit scheduleFrame.
    final phase = SchedulerBinding.instance.schedulerPhase;
    final isBuilding = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;

    if (!isBuilding) {
      setState(() {
        _ready = true;
      });
      return null;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _ready = true;
      });
    });
    WidgetsBinding.instance.scheduleFrame();

    return null;
  }
}

class MapTilesPainter extends CustomPainter {
  final MapProperties properties;
  final TilesRenderer tilesRenderer;
  final double rotation;

  MapTilesPainter(this.properties, this.tilesRenderer, this.rotation);

  @override
  void paint(Canvas canvas, Size size) {
    tilesRenderer.render(canvas, size, rotation);
  }

  @override
  bool shouldRepaint(covariant MapTilesPainter oldDelegate) => true;
}

extension _TileDataModelUiExtension on TileDataModel {
  TileUiModel toUiModel() => TileUiModel(
        tileId: tile.toTileId(),
        position: tilePosition.position,
        tileset: tileset ?? Tileset({}),
        rasterTileset: rasterTileset ?? const RasterTileset(tiles: {}),
        renderData: renderData,
      );
}

extension _TileIdExtension on TileIdentity {
  TileId toTileId() => TileId(z: z, x: x, y: y);
}
