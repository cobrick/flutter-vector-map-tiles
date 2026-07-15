import 'dart:typed_data';

import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../layout/tile_position.dart';
import '../tile_identity.dart';

class TileDataModel {
  late final TileIdentity tile;
  TilePosition tilePosition;
  bool isLoaded = false;
  bool isDisplayReady = false;
  bool preRenderStarted = false;

  /// Set once this tile has been disposed by [MapTiles] because it left the
  /// viewport and is no longer needed. Long-running pre-render work checks this
  /// so it can abort instead of preparing a tile that is no longer visible.
  bool disposed = false;
  Tileset? tileset;
  RasterTileset? rasterTileset;
  Uint8List? renderData;

  TileDataModel(this.tilePosition) : tile = tilePosition.tile;

  void dispose() {
    disposed = true;
    isLoaded = false;
    isDisplayReady = false;
    preRenderStarted = false;
    rasterTileset?.dispose();
    rasterTileset = null;
    tileset = null;
    renderData = null;
  }
}
