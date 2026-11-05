import 'dart:typed_data';

import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../tile_translation.dart';
import 'vector_tile_transform.dart';

/// A tile's vector data as fetched, not yet decoded: per vector source, the
/// bytes of the source tile and where this tile lies in it.
///
/// It is a few byte buffers, cheap to send to a worker isolate. The decoded
/// [Tileset] is an object graph of every feature in the tile, and copying it
/// between isolates blocks the sending isolate for tens of milliseconds.
class EncodedTileset {
  const EncodedTileset(this.tiles, {required this.tileSize});

  final List<EncodedTile> tiles;
  final double tileSize;

  /// Decodes every source tile with [theme]. With [zoom], the zoom the tile
  /// will be laid out at, only the layers the theme draws at it.
  Tileset decode(Theme theme, {double? zoom}) => Tileset({
        for (final tile in tiles)
          tile.source: tile.decode(theme, tileSize, zoom: zoom),
      });
}

/// One vector source's data for a tile.
class EncodedTile {
  const EncodedTile({
    required this.source,
    required this.bytes,
    required this.translation,
  });

  final String source;

  /// The source tile's bytes, or null when the source has no data for this
  /// tile: below the source's minimum zoom, or not found.
  final Uint8List? bytes;

  /// Where this tile lies in the source tile.
  final TileTranslation translation;

  Tile decode(Theme theme, double tileSize, {double? zoom}) {
    final bytes = this.bytes;
    if (bytes == null) {
      return emptyTileData(theme).toTile();
    }
    return decodeVectorTile(theme, bytes, translation, tileSize, zoom: zoom);
  }
}
