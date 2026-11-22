import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/platform/orientation_lock.dart';
import 'package:pure_live/core/platform/orientation_preference.dart';

/// The three-state orientation preference and the list it maps to.
///
/// This exists because "no lock" was never the same thing as "follow the
/// system": the fullscreen path asked for landscape only when a size guard let
/// it, and did nothing otherwise, so a 640 dp tablet stayed upright with no way
/// to ask for the other orientation.
void main() {
  group('OrientationPreference storage', () {
    test('round-trips through the stored key', () {
      for (final value in OrientationPreference.values) {
        expect(OrientationPreferenceX.fromStorage(value.storageKey), value);
      }
    });

    test('an unknown or missing value falls back to following the system', () {
      // Forward compatibility: a key written by a future build that added a
      // value must not silently pin a device to an orientation it did not pick.
      expect(OrientationPreferenceX.fromStorage(null), OrientationPreference.system);
      expect(OrientationPreferenceX.fromStorage(''), OrientationPreference.system);
      expect(OrientationPreferenceX.fromStorage('sideways'), OrientationPreference.system);
    });

    test('the stored keys are stable strings, not enum indices', () {
      // An index would be reinterpreted if a value were inserted ahead of an
      // existing one; these names are the user-facing contract.
      expect(OrientationPreference.landscape.storageKey, 'landscape');
      expect(OrientationPreference.portrait.storageKey, 'portrait');
      expect(OrientationPreference.system.storageKey, 'system');
    });

    test('only the two pins count as locked', () {
      expect(OrientationPreference.landscape.isLocked, isTrue);
      expect(OrientationPreference.portrait.isLocked, isTrue);
      expect(OrientationPreference.system.isLocked, isFalse);
    });
  });

  group('OrientationLock.orientationsFor', () {
    test('landscape pins both landscape directions', () {
      // Both, so the viewer can turn the device either way on a tablet without
      // the UI snapping back.
      expect(OrientationLock.orientationsFor(OrientationPreference.landscape), <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });

    test('portrait pins portrait up only', () {
      // portraitDown would flip a tablet held in a stand upside down.
      expect(OrientationLock.orientationsFor(OrientationPreference.portrait), <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
    });

    test('system sends no preference at all', () {
      // The empty list is how Flutter asks the platform to decide: the system
      // auto-rotate switch and the sensor, including "rotation locked" on the
      // device itself.
      expect(OrientationLock.orientationsFor(OrientationPreference.system), isEmpty);
    });
  });
}
