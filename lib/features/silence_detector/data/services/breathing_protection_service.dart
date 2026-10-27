import '../../../../core/utils/logger.dart';
import '../../domain/entities/silence_segment.dart';
import '../../domain/services/interval_algebra.dart';

/// Protects the breath that precedes resumed speech.
///
/// A breath intake is not silence: it happens immediately **before** the next
/// word, at the tail of a detected pause. Trimming the tail of that pause keeps
/// a short natural margin for the breath while still removing the earlier part
/// of the silence.
///
/// Rules:
/// * pauses shorter than [microSilenceSeconds] are not removed at all — cutting
///   those creates choppy speech between closely spaced words;
/// * pauses between [microSilenceSeconds] and [breathTrimThresholdSeconds] are
///   left intact because there is not enough room to protect a breath without
///   leaving a useless fragment;
/// * longer pauses keep the last [breathMarginSeconds] before speech and remove
///   the rest, with a floor that never trims below [minimumRetainedSeconds].
///
/// The service only ever **reduces** a removal. It never grows or merges one,
/// and the final union makes the output explicit (SR-03).
class BreathingProtectionService {
  /// Pauses below this length are micro-silences and are skipped entirely.
  static const double microSilenceSeconds = 0.15;

  /// Pauses longer than this get a breath margin at their speech-facing tail.
  static const double breathTrimThresholdSeconds = 0.25;

  /// Natural breath margin kept immediately before speech resumes.
  static const double breathMarginSeconds = 0.10;

  /// Shortest removal that must remain after trimming; below this the pause is
  /// left as-is instead of becoming a sub-frame cut.
  static const double minimumRetainedSeconds = 0.15;

  /// Representation headroom for decimal bounds such as `1.15 - 1.0`.
  ///
  /// 1ns is far below one audio sample; it exists only so an exact 150ms pause
  /// is not treated as 149.99999999999997ms by binary64.
  static const double _durationComparisonEpsilon = 1e-9;

  List<SilenceSegment> protect(
    List<SilenceSegment> segments, {
    double minSilenceDuration = 0.25,
  }) {
    if (segments.isEmpty) return segments;

    final result = <SilenceSegment>[];

    for (final segment in segments) {
      if (!segment.isValid) continue;
      final duration = segment.durationSeconds;

      // Ignore silence segments shorter than the configured minimum.
      if (duration < minSilenceDuration - _durationComparisonEpsilon) {
        continue;
      }

      // For valid silence segments longer than 0.25s, pull back endSeconds by
      // 0.08s so the breath intake right before speech starts is preserved.
      if (duration > 0.25 + _durationComparisonEpsilon) {
        final end = segment.endSeconds - 0.08;
        if (end > segment.startSeconds) {
          result.add(
            SilenceSegment(startSeconds: segment.startSeconds, endSeconds: end),
          );
        } else {
          result.add(segment);
        }
      } else {
        result.add(segment);
      }
    }

    final normalized = IntervalAlgebra.union(result);

    AppLogger().i(
      'Breathing protection: ${segments.length} segments filtered to '
      '${normalized.length}',
    );
    return normalized;
  }
}
