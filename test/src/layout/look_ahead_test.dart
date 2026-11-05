import 'dart:ui';

import 'package:test/test.dart';
import 'package:vector_map_tiles/src/layout/look_ahead.dart';

void main() {
  const ms = Duration(milliseconds: 1);

  LookAhead lookAhead() => LookAhead(
    tileSize: 256,
    horizon: const Duration(milliseconds: 500),
    maxTiles: 1,
  );

  test('a still map looks nowhere ahead', () {
    final l = lookAhead();

    expect(l.update(const Offset(100, 100), 12, ms * 0), Offset.zero);
    expect(l.update(const Offset(100, 100), 12, ms * 16), Offset.zero);
  });

  test('a moving map looks ahead in the direction of motion', () {
    final l = lookAhead();
    l.update(const Offset(0, 0), 12, ms * 0);
    // 160 px per 16 ms = 10 000 px/s east, smoothed to half on the first step.
    final ahead = l.update(const Offset(160, 0), 12, ms * 16);

    expect(ahead.dx, greaterThan(0));
    expect(ahead.dy, 0);
  });

  test('looks ahead at most maxTiles tiles per axis', () {
    final l = lookAhead();
    var x = 0.0;
    var ahead = Offset.zero;
    for (var i = 0; i <= 10; i++) {
      ahead = l.update(Offset(-x, x), 12, ms * (16 * i));
      x += 500;
    }

    expect(ahead, const Offset(-256, 256));
  });

  test('settles towards the actual speed', () {
    final l = lookAhead();
    var ahead = Offset.zero;
    // 1 px per ms = 1000 px/s; within 500 ms that is 500 px, capped at 256.
    // Use a slower pan: 0.2 px/ms = 200 px/s -> 100 px within the horizon.
    for (var i = 0; i <= 20; i++) {
      ahead = l.update(Offset(0, 3.2 * i), 12, ms * (16 * i));
    }

    expect(ahead.dy, closeTo(100, 1));
  });

  test('a zoom-level change resets it', () {
    final l = lookAhead();
    l.update(const Offset(0, 0), 12, ms * 0);
    l.update(const Offset(160, 0), 12, ms * 16);

    expect(l.update(const Offset(320, 0), 13, ms * 32), Offset.zero);
  });

  test('a pause between updates resets it', () {
    final l = lookAhead();
    l.update(const Offset(0, 0), 12, ms * 0);
    l.update(const Offset(160, 0), 12, ms * 16);

    expect(l.update(const Offset(170, 0), 12, ms * 400), Offset.zero);
  });
}
