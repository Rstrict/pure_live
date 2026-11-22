import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/player/presentation/fullscreen_window.dart';

/// Orientation locking must not be decided by screen size.
///
/// The guard used to refuse the lock whenever the shortest side reached 600 dp,
/// which excluded exactly the device this was reported on: a Huawei M6 reports
/// 1600 px at 400 dpi, i.e. 640 x 1000 dp in portrait, so `landscape()` never
/// sent a request and fullscreen stayed upright.
void main() {
  group('supportsOrientationLockForLogicalDisplay', () {
    test('a 640 dp tablet may lock landscape', () {
      // The measured device: shortest side is 640 dp, one dp-group past the old
      // 600 dp cutoff. This is the regression under test.
      expect(supportsOrientationLockForLogicalDisplay(const Size(640, 1000)), isTrue);
    });

    test('a phone may lock landscape', () {
      expect(supportsOrientationLockForLogicalDisplay(const Size(360, 800)), isTrue);
      expect(supportsOrientationLockForLogicalDisplay(const Size(411, 891)), isTrue);
    });

    test('a large tablet may lock landscape', () {
      // A 12" class device. Refusing here would be the same bug at a bigger
      // size, so the answer must not depend on where the cutoff sits.
      expect(supportsOrientationLockForLogicalDisplay(const Size(1024, 1366)), isTrue);
      expect(supportsOrientationLockForLogicalDisplay(const Size(1280, 800)), isTrue);
    });

    test('an already-landscape display may still lock', () {
      // The check runs before the request, so it can be reached while the
      // window is already wide. Size order must not change the answer.
      expect(supportsOrientationLockForLogicalDisplay(const Size(1000, 640)), isTrue);
    });

    test('a degenerate size does not throw', () {
      expect(supportsOrientationLockForLogicalDisplay(Size.zero), isTrue);
    });
  });
}
