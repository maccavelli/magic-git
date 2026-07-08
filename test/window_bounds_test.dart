// WindowBoundsStore.boundsOnDisplay: the multi-monitor restore guard. A saved
// window position is only trusted if it still overlaps a currently-connected
// display enough to be reachable — otherwise the window would open off-screen
// on a since-unplugged/rearranged monitor (flashing there, then snapping to the
// main display). Pure geometry, no plugins.

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';

void main() {
  // A typical laptop primary display at the origin, and an external monitor
  // docked to its right (top-left at x = 1920).
  const primary = Rect.fromLTWH(0, 0, 1920, 1080);
  const external = Rect.fromLTWH(1920, 0, 2560, 1440);

  bool on(
    (double, double, double, double) b, [
    List<Rect> frames = const [primary, external],
  ]) =>
      WindowBoundsStore.boundsOnDisplay(b, frames);

  test('a window sitting on the primary display is kept', () {
    expect(on((100, 100, 1080, 720)), isTrue);
  });

  test('a window on a still-connected external display is kept', () {
    expect(on((2200, 300, 1080, 720)), isTrue);
  });

  test('the same external position is dropped once that monitor is gone', () {
    // Only the primary remains connected — the saved rect lands entirely on the
    // vanished external monitor, so it must not be restored.
    expect(on((2200, 300, 1080, 720), const [primary]), isFalse);
  });

  test('a monitor arranged to the left/above (negative origin) is handled', () {
    const left = Rect.fromLTWH(-1920, -200, 1920, 1080);
    expect(on((-1600, 100, 1080, 720), const [primary, left]), isTrue);
  });

  test('a window only barely peeking onto a display is dropped', () {
    // Overlaps the primary by just 10px horizontally — below minOnscreen, so
    // there's not enough of the title bar to grab.
    expect(on((1910.0, 100.0, 1080.0, 720.0), const [primary]), isFalse);
  });

  test('enough overlap on both axes (a partial drag off-edge) is kept', () {
    // Pushed off the right/bottom edge but still 200px on-screen in both axes.
    expect(on((1720.0, 880.0, 1080.0, 720.0), const [primary]), isTrue);
  });

  test('an empty display list (probe failed) trusts the saved bounds', () {
    expect(on((2200, 300, 1080, 720), const []), isTrue);
  });
}
