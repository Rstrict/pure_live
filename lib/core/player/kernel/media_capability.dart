import 'dart:io';

import 'package:flutter/services.dart';

/// Whether this device can decode a given video size and frame rate in hardware.
///
/// The player used to infer "weak hardware" from core count, which cannot separate
/// a device that decodes 1080p60 in its own decoder from one that silently falls
/// back to software and drops frames. On Android the platform answers this
/// directly through `MediaCodecList`, so the app asks instead of guessing.
///
/// Non-Android platforms answer [unknown]: their decoder story is handled by the
/// per-platform kernel profile, and inventing a Linux/Windows answer here would put
/// a guess where the app previously had none.
class MediaCapability {
  const MediaCapability({
    required this.isAndroid,
    required this.sdkInt,
    required this.avcHardware,
    required this.hevcHardware,
    required this.avcFrameRateOk,
    required this.hevcFrameRateOk,
    required this.decoderNames,
  });

  /// The answer for a platform this probe does not cover, or one that failed.
  const MediaCapability.unknown()
    : isAndroid = false,
      sdkInt = 0,
      avcHardware = false,
      hevcHardware = false,
      avcFrameRateOk = false,
      hevcFrameRateOk = false,
      decoderNames = const <String>[];

  final bool isAndroid;
  final int sdkInt;
  final bool avcHardware;
  final bool hevcHardware;
  final bool avcFrameRateOk;
  final bool hevcFrameRateOk;
  final List<String> decoderNames;

  /// Whether hardware decoding is worth attempting for this size.
  ///
  /// Only a reported hardware decoder for the actual size counts. Frame-rate support
  /// is reported separately because a decoder that manages 1080p30 will stutter on a
  /// 1080p60 room even though it is "hardware".
  bool get hasHardwareDecoder => avcHardware || hevcHardware;

  /// Whether the device should avoid asking for high frame rates.
  ///
  /// True only when a hardware decoder exists but none accepts the frame rate: that
  /// is the case where software fallback loses more than a lower frame-rate source
  /// would.
  bool get highFrameRateRisky => hasHardwareDecoder && !avcFrameRateOk && !hevcFrameRateOk;

  @override
  String toString() =>
      'MediaCapability(android=$isAndroid sdk=$sdkInt avc=$avcHardware/$avcFrameRateOk '
      'hevc=$hevcHardware/$hevcFrameRateOk ${decoderNames.join(",")})';
}

/// Reads [MediaCapability] from the platform and caches it for the process.
///
/// The decoder table does not change while the app runs, so one query per size is
/// enough; a room open must not pay a channel round trip every time.
abstract final class MediaCapabilityService {
  static const MethodChannel _channel = MethodChannel('pure_live/media_capability');

  static final Map<String, MediaCapability> _cache = <String, MediaCapability>{};

  /// Describes the device for [width]x[height] at [frameRate].
  ///
  /// Never throws: an unsupported platform or a failed channel call answers
  /// [MediaCapability.unknown], and callers must treat "unknown" as "no opinion"
  /// rather than "cannot decode".
  static Future<MediaCapability> describe({int width = 1920, int height = 1080, int frameRate = 60}) async {
    if (!Platform.isAndroid) return const MediaCapability.unknown();
    final key = '${width}x$height@$frameRate';
    final cached = _cache[key];
    if (cached != null) return cached;

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('describe', <String, Object?>{
        'width': width,
        'height': height,
        'frameRate': frameRate,
      });
      if (raw == null) return const MediaCapability.unknown();
      final capability = _fromMap(raw);
      _cache[key] = capability;
      return capability;
    } catch (_) {
      // A missing plugin (a test host, an older native build) is not a verdict
      // about the hardware.
      return const MediaCapability.unknown();
    }
  }

  /// Test seam: clears the per-size cache.
  static void resetCacheForTesting() => _cache.clear();

  static MediaCapability _fromMap(Map<String, Object?> raw) {
    final avc = raw['avc'] is Map ? Map<String, Object?>.from(raw['avc'] as Map) : const <String, Object?>{};
    final hevc = raw['hevc'] is Map ? Map<String, Object?>.from(raw['hevc'] as Map) : const <String, Object?>{};
    final names = <String>[
      for (final value in (avc['decoders'] as List?) ?? const <Object?>[])
        if (value is String && value.isNotEmpty) value,
      for (final value in (hevc['decoders'] as List?) ?? const <Object?>[])
        if (value is String && value.isNotEmpty) value,
    ];
    return MediaCapability(
      isAndroid: true,
      sdkInt: raw['sdkInt'] is int ? raw['sdkInt'] as int : 0,
      avcHardware: avc['hardware'] == true,
      hevcHardware: hevc['hardware'] == true,
      avcFrameRateOk: avc['supportsFrameRate'] == true,
      hevcFrameRateOk: hevc['supportsFrameRate'] == true,
      decoderNames: List<String>.unmodifiable(names),
    );
  }
}
