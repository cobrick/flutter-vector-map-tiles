import 'dart:ui';

/// Estimates where the map is heading, so tiles about to scroll into view
/// can load before they are on screen.
///
/// Fed with the map centre in pixels at the tile zoom on every update, it
/// returns how far the centre will move within [horizon] at the current
/// (smoothed) speed, capped at [maxTiles] tiles per axis. The viewport is
/// widened by that much on the side the map moves towards. A still map, a
/// zoom-level change or a pause between updates resets it to zero.
class LookAhead {
  LookAhead({
    required this.tileSize,
    this.horizon = const Duration(milliseconds: 350),
    this.maxTiles = 1.0,
  });

  final int tileSize;
  final Duration horizon;
  final double maxTiles;

  /// Updates further apart than this mean the map stopped in between.
  static const _maxGap = Duration(milliseconds: 250);

  Offset? _lastCentre;
  Duration? _lastTime;
  int? _tileZoom;
  Offset _velocity = Offset.zero; // pixels per second

  /// Records the centre at [time] and returns the look-ahead offset in
  /// pixels at the tile zoom.
  Offset update(Offset centre, int tileZoom, Duration time) {
    final lastCentre = _lastCentre;
    final lastTime = _lastTime;
    if (lastCentre == null || lastTime == null || tileZoom != _tileZoom) {
      _velocity = Offset.zero;
    } else {
      final dt = time - lastTime;
      if (dt <= Duration.zero) {
        return _offset();
      }
      if (dt > _maxGap) {
        _velocity = Offset.zero;
      } else {
        final seconds = dt.inMicroseconds / Duration.microsecondsPerSecond;
        final velocity = (centre - lastCentre) / seconds;
        _velocity = _velocity * 0.5 + velocity * 0.5;
      }
    }
    _lastCentre = centre;
    _lastTime = time;
    _tileZoom = tileZoom;
    return _offset();
  }

  Offset _offset() {
    final seconds = horizon.inMicroseconds / Duration.microsecondsPerSecond;
    final cap = maxTiles * tileSize;
    return Offset(
      (_velocity.dx * seconds).clamp(-cap, cap),
      (_velocity.dy * seconds).clamp(-cap, cap),
    );
  }
}
