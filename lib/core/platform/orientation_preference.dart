/// What the app should do about screen orientation.
///
/// This is a device-level preference, not a per-room one: a viewer who wants
/// landscape holds the tablet one way, and the app should keep it that way
/// across rooms instead of re-deciding on every entry.
///
/// It exists because "don't lock" never actually meant "follow the system".
/// The fullscreen path asked the platform for landscape only when a size guard
/// allowed it, and did nothing at all otherwise — so a large-screen device sat
/// wherever it happened to be when the room opened, with no way to ask for the
/// other orientation. The three states below make the intent explicit.
enum OrientationPreference {
  /// Lock the UI to landscape wherever an orientation lock is possible.
  landscape,

  /// Lock the UI to portrait.
  portrait,

  /// Hand orientation back to the platform: the sensor decides.
  system,
}

extension OrientationPreferenceX on OrientationPreference {
  /// Stable key used for persistence; never derive storage from the index, or
  /// inserting a value would silently reinterpret a stored preference.
  String get storageKey => switch (this) {
    OrientationPreference.landscape => 'landscape',
    OrientationPreference.portrait => 'portrait',
    OrientationPreference.system => 'system',
  };

  static OrientationPreference fromStorage(String? value) {
    return switch (value) {
      'landscape' => OrientationPreference.landscape,
      'portrait' => OrientationPreference.portrait,
      _ => OrientationPreference.system,
    };
  }

  /// Whether this preference pins a single orientation, i.e. whether the
  /// platform must be told what to do rather than left alone.
  bool get isLocked => this != OrientationPreference.system;
}
