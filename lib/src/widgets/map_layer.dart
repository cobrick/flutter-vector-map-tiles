import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../loader/caching_tile_loader.dart';
import '../loader/encoded_tileset.dart';
import '../loader/theme_repo.dart';
import '../model/map_properties.dart';
import '../model/tile_data_model.dart';
import 'abstract_map_layer_state.dart';

class MapLayer extends AbstractMapLayer {
  const MapLayer({super.key, required super.mapProperties})
      : super(tileLoaderFactory: createEncodedTileLoader);

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

  /// Draws again only while the renderer still has work that shows on screen
  /// (tiles held back by its upload budget, labels fading in), instead of
  /// for a fixed second after every tile change. A layer without labels
  /// then stops redrawing as soon as its tiles are built.
  @override
  bool get needsAnimationFrame => tilesRenderer.needsAnotherFrame;

  @override
  Future<void> preRender(TileDataModel tile) {
    return super.preRender(tile).then((_) async {
      // The tile can scroll out of view (and be disposed by MapTiles) while it
      // was loading or is being prepared. Abort at each step so a fast
      // multi-level zoom doesn't spend atlas/isolate/GPU work on tiles that are
      // no longer visible.
      if (tile.disposed) return;
      final tileID = tile.tile.key();
      final zoom = this.zoom;
      try {
        var output = await _preRenderOnWorker(
            tile, zoom, tilesRenderer.preRenderInput(tileID),
            retry: false);
        if (output.renderData == null) {
          // Its labels need glyphs that no atlas holds yet. Generate them
          // here, on the UI isolate, and lay the tile out again.
          if (tile.disposed) return;
          final input = await tilesRenderer.loadGlyphs(output, tileID);
          if (tile.disposed) return;
          output = await _preRenderOnWorker(tile, zoom, input, retry: true);
        }
        if (tile.disposed) return;
        tilesRenderer.keepUsedAtlases(output, tileID);
        tile.renderData ??= output.renderData;
        // Laid out: the encoded tile is no longer needed.
        tile.encodedTileset = null;
      } on CancellationException {
        // Disposed while its job waited for a worker.
      }
    });
  }

  /// Decodes [tile] and lays it out on one of the executor's isolates. The
  /// job carries the encoded tile, never a decoded one: copying a decoded
  /// tile's object graph to an isolate blocks the UI thread for tens of
  /// milliseconds.
  Future<PreRenderOutput> _preRenderOnWorker(
    TileDataModel tile,
    double zoom,
    PreRenderInput input, {
    required bool retry,
  }) {
    final theme = widget.mapProperties.theme;
    final name = retry ? 'pre-render-retry' : 'pre-render';
    final encoded = tile.encodedTileset;
    // Without it the tile would be laid out blank, and stay blank.
    assert(encoded != null, 'MapLayer needs a loader that keeps tiles encoded');
    return executor.submit(Job(
      name,
      _preRenderTile,
      _PreRenderJob(
        theme.id,
        zoom,
        encoded ?? const EncodedTileset([], tileSize: 256),
        input,
      ),
      cancelled: () => tile.disposed,
      deduplicationKey:
          '$name:${theme.id}-${theme.version}-$zoom-${tile.tile.key()}',
    ));
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

/// A tile to lay out on a worker isolate, as plain data.
class _PreRenderJob {
  const _PreRenderJob(this.themeId, this.zoom, this.tileset, this.input);

  final String themeId;
  final double zoom;
  final EncodedTileset tileset;
  final PreRenderInput input;
}

/// Runs on a worker isolate: decodes the tile and lays it out there, so the
/// decoded tile never crosses isolates. Only the render data comes back.
PreRenderOutput _preRenderTile(_PreRenderJob job) {
  final theme = ThemeRepo.themeById[job.themeId]!;
  // Decoding only what the theme draws at this zoom keeps the garbage down:
  // the workers share their heap with the UI isolate, and every collection
  // pauses the UI thread too.
  final tileset = job.tileset.decode(theme, zoom: job.zoom);
  return TilesRenderer.preRender(theme, job.zoom, tileset, job.input);
}
