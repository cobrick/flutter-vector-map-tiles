import 'dart:isolate';
import 'dart:typed_data';

import 'package:executor_lib/executor_lib.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/cache/cache.dart';
import 'package:vector_map_tiles/src/loader/encoded_tileset.dart';
import 'package:vector_map_tiles/src/loader/theme_repo.dart';
import 'package:vector_map_tiles/src/loader/vector_tile_loader.dart';
import 'package:vector_map_tiles/src/model/map_properties.dart';
import 'package:vector_map_tiles/src/tile_identity.dart';
import 'package:vector_map_tiles/src/tile_translation.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

class _Provider extends VectorTileProvider {
  _Provider(
    this.type, {
    this.minimumZoom = 0,
    this.maximumZoom = 14,
    this.statusCode,
  });

  @override
  final TileProviderType type;
  @override
  final int minimumZoom;
  @override
  final int maximumZoom;
  final int? statusCode;
  final requested = <TileIdentity>[];

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    requested.add(tile);
    final statusCode = this.statusCode;
    if (statusCode != null) {
      throw ProviderException(
        message: 'HTTP $statusCode',
        statusCode: statusCode,
        retryable: Retryable.none,
      );
    }
    return Uint8List.fromList([tile.z, tile.x, tile.y]);
  }
}

/// Loads every key, or hands back [bytes] when set.
class _Cache extends Cache {
  Uint8List? bytes;

  @override
  Future<Uint8List> get(String key, {required LoadFunction load}) async =>
      bytes ?? await load(key);
}

void main() {
  final theme = ProvidedThemes.lightTheme();
  late _Provider vector;
  late _Cache cache;

  setUp(() {
    vector = _Provider(TileProviderType.vector);
    cache = _Cache();
  });

  Future<EncodedTileset> loadEncoded(
    TileIdentity tile, {
    bool cancelled = false,
  }) =>
      VectorTileLoader(
        tileSize: 256,
        mapProperties: MapProperties(
          tileProviders: TileProviders({
            'openmaptiles': vector,
            'natural_earth_shaded_relief': _Provider(TileProviderType.raster),
          }),
          theme: theme,
          tileOffset: TileOffset.DEFAULT,
          concurrency: 0,
          cacheProperties: const CacheProperties(
            fileCacheTtl: Duration.zero,
            fileCacheMaximumSizeInBytes: 0,
            cacheFolder: null,
          ),
        ),
        executor: QueueExecutor(),
        cache: cache,
        themeRepo: ThemeRepo(),
      ).loadEncoded(tile, () => cancelled);

  group('loadEncoded', () {
    test('fetches each vector source tile and leaves it encoded', () async {
      final encoded = await loadEncoded(TileIdentity(10, 5, 6));

      expect(encoded.tileSize, 256);
      expect(encoded.tiles, hasLength(1));
      final tile = encoded.tiles.single;
      expect(tile.source, 'openmaptiles');
      expect(tile.bytes, [10, 5, 6]);
      expect(tile.translation.isTranslated, isFalse);
      expect(ThemeRepo.themeById[theme.id], same(theme));
    });

    test('past the source maximum zoom, fetches the parent tile', () async {
      final encoded = await loadEncoded(TileIdentity(16, 9, 10));

      final tile = encoded.tiles.single;
      expect(vector.requested, [TileIdentity(14, 2, 2)]);
      expect(tile.bytes, [14, 2, 2]);
      expect(tile.translation.fraction, 4);
      expect(tile.translation.xOffset, 1);
      expect(tile.translation.yOffset, 2);
    });

    test('has no bytes below the source minimum zoom', () async {
      vector = _Provider(TileProviderType.vector, minimumZoom: 5);

      final encoded = await loadEncoded(TileIdentity(3, 1, 1));

      expect(encoded.tiles.single.bytes, isNull);
      expect(vector.requested, isEmpty);
    });

    for (final statusCode in [404, 204]) {
      test('has no bytes for a tile the source answers with $statusCode',
          () async {
        vector = _Provider(TileProviderType.vector, statusCode: statusCode);

        final encoded = await loadEncoded(TileIdentity(10, 5, 6));

        expect(encoded.tiles.single.bytes, isNull);
      });
    }

    test('passes on other provider errors', () async {
      vector = _Provider(TileProviderType.vector, statusCode: 500);

      await expectLater(
        loadEncoded(TileIdentity(10, 5, 6)),
        throwsA(isA<ProviderException>()),
      );
    });

    test('stops when the tile is cancelled while it loads', () async {
      await expectLater(
        loadEncoded(TileIdentity(10, 5, 6), cancelled: true),
        throwsA(isA<CancellationException>()),
      );
    });

    test('copies a view out of its larger buffer', () async {
      cache.bytes = Uint8List.sublistView(
          Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]), 2, 5);

      final bytes =
          (await loadEncoded(TileIdentity(10, 5, 6))).tiles.single.bytes!;

      expect(bytes, [2, 3, 4]);
      expect(bytes.offsetInBytes, 0);
      expect(bytes.buffer.lengthInBytes, 3);
    });
  });

  test('decode gives every source a tile, empty without bytes', () {
    final tileset = EncodedTileset([
      EncodedTile(
        source: 'openmaptiles',
        bytes: null,
        translation: TileTranslation.identity(TileIdentity(3, 1, 1)),
      ),
    ], tileSize: 256)
        .decode(theme);

    expect(tileset.tiles.keys, ['openmaptiles']);
    expect(tileset.tile('openmaptiles')!.layers, isEmpty);
  });

  test('an encoded tileset can be sent to a worker isolate and back', () async {
    final encoded = await loadEncoded(TileIdentity(16, 9, 10));

    final received = await Isolate.run(() => encoded);

    final tile = received.tiles.single;
    expect(tile.bytes, [14, 2, 2]);
    expect(tile.translation.xOffset, 1);
    expect(received.tileSize, 256);
  });
}
