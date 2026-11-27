import 'package:executor_lib/executor_lib.dart';
import 'theme_repo.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../cache/cache.dart';
import '../model/map_properties.dart';
import '../model/tile_data_model.dart';
import 'encoded_tileset.dart';
import 'raster_tile_loader.dart';
import 'tile_loader.dart';
import 'vector_tile_loader.dart';

class DefaultTileLoader extends TileLoader {
  final double tileSize;
  final MapProperties mapProperties;
  final Cache cache;
  final Executor executor;
  ThemeRepo themeRepo;

  /// Whether to decode vector tiles into [TileDataModel.tileset]. If false,
  /// they stay encoded in [TileDataModel.encodedTileset], for a layer that
  /// decodes them on a worker isolate.
  final bool decodeVectorTiles;

  DefaultTileLoader(
      {required this.tileSize,
      required this.mapProperties,
      required this.executor,
      required this.cache,
      required this.themeRepo,
      this.decodeVectorTiles = true});

  @override
  Future<void> load(TileDataModel model, bool Function() cancelled) async {
    RasterTileset? rasterTileset;
    try {
      final vectorTileLoader = VectorTileLoader(
          tileSize: tileSize,
          mapProperties: mapProperties,
          executor: executor,
          cache: cache,
          themeRepo: themeRepo);
      Tileset? tileset;
      EncodedTileset? encodedTileset;
      if (decodeVectorTiles) {
        tileset = await vectorTileLoader.load(model.tile, cancelled);
      } else {
        encodedTileset =
            await vectorTileLoader.loadEncoded(model.tile, cancelled);
      }
      rasterTileset = await RasterTileLoader(
        mapProperties: mapProperties,
        cache: cache,
      ).load(model.tile, cancelled);

      model.tileset = tileset;
      model.encodedTileset = encodedTileset;
      model.rasterTileset = rasterTileset;
      model.isLoaded = true;
    } catch (e) {
      rasterTileset?.dispose();
      rethrow;
    }
  }
}
