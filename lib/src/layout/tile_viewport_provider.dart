import 'dart:math';
import 'dart:ui';

import '../../vector_map_tiles.dart';
import 'map_state.dart';
import 'tile_viewport.dart';

class TileViewportProvider {
  final MapState mapState;
  final TileOffset tileOffset;
  final int tileSize;

  TileViewportProvider({
    required this.mapState,
    required this.tileOffset,
    required this.tileSize,
  });

  /// The tiles covering the map. [lookAhead] (pixels at the tile zoom, see
  /// `LookAhead`) widens the bounds on the side the map is moving towards.
  TileViewport currentViewport({Offset lookAhead = Offset.zero}) {
    final visible = _tiledPixelBounds();
    final pixelBounds = Rect.fromLTRB(
      visible.left + min(lookAhead.dx, 0.0),
      visible.top + min(lookAhead.dy, 0.0),
      visible.right + max(lookAhead.dx, 0.0),
      visible.bottom + max(lookAhead.dy, 0.0),
    );
    final topLeft = Offset(
      (pixelBounds.left / tileSize).floorToDouble(),
      (pixelBounds.top / tileSize).floorToDouble(),
    );
    final bottomRight = Offset(
      (pixelBounds.right / tileSize).ceilToDouble() - 1,
      (pixelBounds.bottom / tileSize).ceilToDouble() - 1,
    );
    final tileRect = Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
    double clampedTileZoom = _clampedTileZoom();
    return TileViewport(zoom: clampedTileZoom.toInt(), bounds: tileRect);
  }

  double tileZoom() => max(1.0, (mapState.zoom + tileOffset.zoomOffset));

  /// The integer zoom of the tiles in use.
  int get clampedTileZoom => _clampedTileZoom().toInt();

  /// The map centre in pixels at [clampedTileZoom].
  Offset centreAtTileZoom() =>
      mapState.projectAtZoom(mapState.center, _clampedTileZoom());

  double _clampedTileZoom() => tileZoom().floorToDouble();

  Rect _tiledPixelBounds() {
    final zoom = mapState.zoom;
    final clampedTileZoom = _clampedTileZoom();
    final scale = mapState.getZoomScale(zoom, clampedTileZoom);
    final center = mapState.projectAtZoom(
      mapState.center,
      clampedTileZoom,
    ); // Offset
    final halfSize = mapState.size / (scale * 2); // Size

    final halfSizeOffset = Offset(halfSize.width, halfSize.height);
    final topLeft = center - halfSizeOffset;
    final bottomRight = center + halfSizeOffset;

    return Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
  }
}
