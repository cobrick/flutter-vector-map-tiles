import 'dart:typed_data';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../cache/cache.dart';
import '../model/map_properties.dart';
import '../tile_translation.dart';
import 'encoded_tileset.dart';
import 'theme_repo.dart';
import 'vector_tile_transform.dart';

class VectorTileLoader {
  final double tileSize;
  final MapProperties mapProperties;
  final Cache cache;
  late final VectorTileTransform transform;
  final Executor executor;
  final ThemeRepo themeRepo;

  VectorTileLoader({
    required this.tileSize,
    required this.mapProperties,
    required this.executor,
    required this.cache,
    required this.themeRepo,
  }) {
    transform = VectorTileTransform(
        executor: executor,
        theme: mapProperties.theme,
        tileSize: tileSize,
        themeRepo: themeRepo);
  }

  Future<Tileset> load(TileIdentity tile, bool Function() cancelled) async {
    final tilesBySource = <String, Tile>{};
    for (final MapEntry(key: source, value: provider) in _vectorProviders) {
      final (bytes, translation) =
          await _fetch(source, provider, tile, cancelled);
      tilesBySource[source] = bytes == null
          ? emptyTileData(mapProperties.theme).toTile()
          : await transform.apply(bytes, translation, cancelled);
    }
    return Tileset(tilesBySource);
  }

  /// Fetches the tile's vector source tiles without decoding them, for a
  /// layer that decodes them on a worker isolate. Completes once the theme
  /// is set up on the executor's isolates, ready for that.
  Future<EncodedTileset> loadEncoded(
    TileIdentity tile,
    bool Function() cancelled,
  ) async {
    final tiles = <EncodedTile>[];
    for (final MapEntry(key: source, value: provider) in _vectorProviders) {
      final (bytes, translation) =
          await _fetch(source, provider, tile, cancelled);
      tiles.add(EncodedTile(
        source: source,
        bytes: bytes == null ? null : _compact(bytes),
        translation: translation,
      ));
    }
    final themeId = mapProperties.theme.id;
    if (!themeRepo.isThemeReady(themeId)) {
      await themeRepo.waitForTheme(themeId);
    }
    return EncodedTileset(tiles, tileSize: tileSize);
  }

  Iterable<MapEntry<String, VectorTileProvider>> get _vectorProviders =>
      mapProperties.theme.tileSources
          .map(
            (source) =>
                MapEntry(source, mapProperties.tileProviders.get(source)),
          )
          .where((e) => e.value.type == TileProviderType.vector);

  /// The bytes of [source]'s tile that holds [tile], or null when the source
  /// has none, and where [tile] lies in it.
  Future<(Uint8List?, TileTranslation)> _fetch(
    String source,
    VectorTileProvider provider,
    TileIdentity tile,
    bool Function() cancelled,
  ) async {
    if (tile.z < provider.minimumZoom) {
      return (null, TileTranslation.identity(tile));
    }
    final translation =
        SlippyMapTranslator(provider.maximumZoom).translate(tile);
    final tileToLoad = translation.translated;
    final themeKey = mapProperties.theme.id;
    final cacheKey =
        '${themeKey}_${source}_${tileToLoad.z}_${tileToLoad.x}_${tileToLoad.y}.pbf';
    final Uint8List bytes;
    try {
      bytes = await cache.get(
        cacheKey,
        load: (key) => provider.provide(tileToLoad),
      );
    } on ProviderException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 204) {
        return (null, translation);
      }
      rethrow;
    }
    if (cancelled()) {
      throw CancellationException();
    }
    return (bytes, translation);
  }

  /// [bytes] in a buffer of their own: sending a view to an isolate copies
  /// the whole buffer behind it.
  static Uint8List _compact(Uint8List bytes) => bytes.offsetInBytes == 0 &&
          bytes.lengthInBytes == bytes.buffer.lengthInBytes
      ? bytes
      : Uint8List.fromList(bytes);
}
