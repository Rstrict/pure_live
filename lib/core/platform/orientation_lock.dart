import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:pure_live/core/platform/orientation_preference.dart';

/// Puts the device into the orientation the user asked for.
///
/// Everything that changes orientation funnels through here so there is one
/// answer to "which way should the screen be": the settings page, the fullscreen
/// transition and the app start-up all ask the same question and get the same
/// platform call.
///
/// The reason this indirection exists: orientation used to be decided in three
/// separate places with three different rules. The fullscreen path asked for
/// landscape only when a physical-size guard allowed it, going back to portrait
/// was another call, and nothing at all happened for a viewer who wanted one
/// fixed orientation. On a large-screen device the guard refused the landscape
/// request outright, so "fullscreen" silently stayed upright.
abstract final class OrientationLock {
  static const List<DeviceOrientation> _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static const List<DeviceOrientation> _portrait = <DeviceOrientation>[DeviceOrientation.portraitUp];

  /// The orientations a preference maps to.
  ///
  /// `system` is the empty list, which is how Flutter says "no preference": the
  /// platform's own rotation setting decides, including whether the sensor is
  /// enabled at all.
  @visibleForTesting
  static List<DeviceOrientation> orientationsFor(OrientationPreference preference) => switch (preference) {
    OrientationPreference.landscape => _landscape,
    OrientationPreference.portrait => _portrait,
    OrientationPreference.system => const <DeviceOrientation>[],
  };

  /// Applies [preference] to the platform.
  ///
  /// Never throws: orientation is cosmetic relative to playback, and a desktop
  /// build (or a platform that refuses the request) must not fail the caller.
  static Future<void> apply(OrientationPreference preference) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await SystemChrome.setPreferredOrientations(orientationsFor(preference));
    } catch (error, stackTrace) {
      debugPrint('OrientationLock.apply(${preference.storageKey}) failed: $error');
      debugPrint('$stackTrace');
    }
  }
}
