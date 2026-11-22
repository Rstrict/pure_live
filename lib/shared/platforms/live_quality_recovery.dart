import 'package:pure_live/core/models/live_play_quality.dart';

/// Picks the freshly advertised quality that still represents the one the
/// viewer had committed.
///
/// Recovery must not fall back to "whatever the platform lists first": that
/// silently downgrades a viewer who was watching source quality, and it hides a
/// room whose quality table genuinely shrank. The match is by stable
/// [LivePlayQuality.selectionId], which is the platform's own identifier when the
/// adapter supplies one and the visible label otherwise — an adapter with no id
/// therefore already matches by label through the same path.
///
/// A tier the platform stopped advertising returns `null` rather than a
/// substitute. Whether "that quality is gone" should be shown to the viewer or
/// retried is the caller's decision, not something to paper over here.
LivePlayQuality? matchRecoveredQuality(Iterable<LivePlayQuality> fresh, {required Object requestedSelectionId}) {
  final wanted = requestedSelectionId.toString();
  for (final quality in fresh) {
    if (quality.selectionId.toString() == wanted) return quality;
  }
  return null;
}
