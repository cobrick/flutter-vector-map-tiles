import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../vector_map_tiles.dart';
import '../flutter_map/flutter_map_state.dart';
import '../flutter_map/flutter_map_zoom_scaler.dart';
import '../layout/tile_layout.dart';
import '../layout/tile_viewport_provider.dart';
import '../model/map_tiles.dart';
import '../tile_offset.dart';

typedef MapUpdatedCallback = void Function();

class FlutterMapAdapter {
  final tileSize = 256;
  StreamSubscription<MapEvent>? _subscription;
  final TileOffset tileOffset;
  final MapTiles mapTiles;
  final MapUpdatedCallback mapUpdated;
  double _zoom = 1.0;
  double _rotation = 0.0;

  FlutterMapAdapter({
    required this.tileOffset,
    required this.mapUpdated,
    required this.mapTiles,
  });

  double get zoom => _zoom;
  double get rotation => _rotation;

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  void update(BuildContext context) {
    final controller = MapController.maybeOf(context);
    if (controller != null) {
      _subscription ??= controller.mapEventStream.listen(_mapUpdated);
      final mapState = FlutterMapState(camera: controller.camera);
      final viewportProvider = TileViewportProvider(
        mapState: mapState,
        tileOffset: tileOffset,
        tileSize: tileSize,
      );
      final viewport = viewportProvider.currentViewport();
      var layout = TileLayout(
        offset: tileOffset,
        viewport: viewport,
        tileSize: tileSize,
      );
      _zoom = controller.camera.zoom;
      _rotation = controller.camera.rotation;
      final zoomScaler = FlutterMapZoomScaler(crs: controller.camera.crs)
        ..updateMapZoomScale(_zoom);
      final tilePositions = layout.computeTilePositions(mapState, zoomScaler);
      mapTiles.updateTiles(tilePositions);
      for (final model in mapTiles.obsoleteModels) {
        model.tilePosition = layout.positionTile(
          mapState,
          zoomScaler,
          model.tile,
        );
      }
    }
  }

  void _mapUpdated(MapEvent event) => mapUpdated();
}
