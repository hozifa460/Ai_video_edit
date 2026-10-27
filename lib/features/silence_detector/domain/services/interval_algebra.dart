import '../entities/silence_segment.dart';

/// Shortest interval this feature will emit as a cut. One millisecond is far
/// below one frame at any real frame rate, so anything shorter is noise from a
/// parser or a ruler, not content the user asked to delete.
const double kMinSilenceIntervalSeconds = 0.001;

/// Shortest kept range tolerated **at a timeline boundary**.
///
/// A silence that already starts at `0` or ends at `totalDuration` has no
/// speech on that side, yet the speech guards and the breath margin still carve
/// 80-160ms out of it. The complement then reports a fake "speech" sliver such
/// as `[0, 0.08]` or `[total - 0.16, total]`. Phone videos frequently have no
/// video frame inside their last 100ms, so cutting such a range produces a
/// 0-frame segment and the concat fails with "no output".
const double kMinBoundaryKeptSeconds = 0.12;

/// Pure interval algebra for the silence-removal feature.
///
/// Every rule that decides *what gets deleted* funnels through this file, so
/// the detection pipeline, the statistics rendered in the UI, and the FFmpeg
/// cut cannot disagree (SR-03). No plugin, no IO, no globals: each function is
/// a deterministic map from a list of intervals to another list of intervals.
///
/// Invariants of every returned list:
/// * both bounds finite (NaN/Infinity are dropped, never clamped into a range)
/// * `0 <= startSeconds < endSeconds`
/// * ascending by `startSeconds` and pairwise non-overlapping
/// * `endSeconds <= totalDuration` whenever a duration is supplied
/// * an input whose intervals are all invalid yields an empty list, never an
///   exception
///
/// The central safety rule (SR-01/B01-R2): a positive gap between two intervals
/// is **content**, and this algebra will never absorb one. Speech is frequently
/// shorter than the configured minimum silence duration, and even a 10ms gap
/// is 160 samples at 16kHz — enough to hold a consonant onset or a short
/// transition, and there is no evidence it is only numeric jitter. Only truly
/// overlapping or exactly touching intervals are merged, and the merged end is
/// `max(end)` so a contained interval can never shrink the union (SR-19).
///
/// There is deliberately **no gap-tolerance parameter**. An earlier revision
/// passed a 20ms "sample-boundary tolerance" from the silencedetect pass merge;
/// review B01-R2 showed it silently deleted unclassified audio, so the parameter
/// is gone rather than defaulted. Any future policy that removes content
/// between intervals needs its own explicit, separately reviewed contract — not
/// a tolerance smuggled in under another name.
class IntervalAlgebra {
  IntervalAlgebra._();

  /// Returns [value] when it is finite, otherwise [fallback].
  static double finiteOr(double value, {double fallback = 0}) =>
      value.isFinite ? value : fallback;

  /// Returns [value] when it is finite and positive, otherwise `0`.
  static double nonNegativeOrZero(double value) =>
      value.isFinite && value > 0 ? value : 0;

  /// Validates, clamps, sorts and unions [input].
  ///
  /// [totalDuration] is the length of the timeline the intervals live on. Pass
  /// the **probed video duration**, not an audio or waveform guess (SR-05), so
  /// the tail of a video whose audio is shorter is never clamped away.
  static List<SilenceSegment> normalize(
    List<SilenceSegment> input, {
    required double totalDuration,
    double minLengthSeconds = kMinSilenceIntervalSeconds,
  }) {
    final bound = nonNegativeOrZero(totalDuration);
    final minLength = nonNegativeOrZero(minLengthSeconds);

    final usable = <SilenceSegment>[];
    for (final segment in input) {
      if (!segment.hasFiniteBounds) continue;
      final start = segment.startSeconds < 0 ? 0.0 : segment.startSeconds;
      var end = segment.endSeconds;
      if (end > bound) end = bound;
      if (end - start < minLength) continue;
      if (bound > 0 && start >= bound) continue;
      usable.add(SilenceSegment(startSeconds: start, endSeconds: end));
    }

    return union(usable);
  }

  /// Unions [input] after validating it, without clamping to a duration.
  ///
  /// Sorting happens here so nested, unsorted, and equal intervals all behave
  /// identically. The merged end is the maximum of both ends. Intervals merge
  /// only when they overlap or when the next one starts exactly where the
  /// previous ends — never for a positive gap.
  static List<SilenceSegment> union(List<SilenceSegment> input) {
    if (input.isEmpty) return [];

    final sorted = input.where((s) => s.isValid).toList()
      ..sort((a, b) {
        final byStart = a.startSeconds.compareTo(b.startSeconds);
        if (byStart != 0) return byStart;
        // Longest first on identical starts so the widest end wins the max().
        return b.endSeconds.compareTo(a.endSeconds);
      });

    // Every interval may have been rejected by validation (zero-length,
    // inverted, or non-finite). Reading `first` before this check threw
    // `Bad state: No element` (B01-R3).
    if (sorted.isEmpty) return [];

    final merged = <SilenceSegment>[sorted.first];
    for (var i = 1; i < sorted.length; i++) {
      final current = sorted[i];
      final last = merged.last;
      if (current.startSeconds <= last.endSeconds) {
        merged[merged.length - 1] = SilenceSegment(
          startSeconds: last.startSeconds,
          endSeconds: current.endSeconds > last.endSeconds
              ? current.endSeconds
              : last.endSeconds,
        );
      } else {
        merged.add(current);
      }
    }
    return merged;
  }

  /// Kept ranges inside `[0, totalDurationSeconds]` — the complement of the
  /// normalized removal set. This is the single source of truth for what the
  /// FFmpeg cut keeps, so audio and video are trimmed over identical ranges.
  static List<SilenceSegment> complement(
    List<SilenceSegment> normalized, {
    required double totalDurationSeconds,
  }) {
    final bound = nonNegativeOrZero(totalDurationSeconds);
    if (bound <= 0) return [];

    final kept = <SilenceSegment>[];
    var cursor = 0.0;
    for (final removal in normalized) {
      if (!removal.isValid) continue;
      if (removal.startSeconds > cursor) {
        kept.add(
          SilenceSegment(
            startSeconds: cursor,
            endSeconds: removal.startSeconds,
          ),
        );
      }
      if (removal.endSeconds > cursor) cursor = removal.endSeconds;
    }
    if (cursor < bound) {
      kept.add(SilenceSegment(startSeconds: cursor, endSeconds: bound));
    }
    return _dropBoundarySlivers(kept, bound);
  }

  /// Removes sub-[kMinBoundaryKeptSeconds] kept slivers that touch `t=0` or
  /// `t=totalDuration`, unless they are the only kept range.
  ///
  /// Only the two outer ranges are eligible: an **interior** gap is real speech
  /// between two silences and is preserved at every size, including 1ms
  /// (SR-01/B01-R2). Dropping interior islands to fix a boundary encoding
  /// problem would delete content the user never asked to remove.
  static List<SilenceSegment> _dropBoundarySlivers(
    List<SilenceSegment> kept,
    double bound,
  ) {
    if (kept.length <= 1) return kept;

    final result = <SilenceSegment>[];
    for (var i = 0; i < kept.length; i++) {
      final segment = kept[i];
      final touchesStart = i == 0 && segment.startSeconds <= 0;
      final touchesEnd = i == kept.length - 1 && segment.endSeconds >= bound;
      if ((touchesStart || touchesEnd) &&
          segment.durationSeconds < kMinBoundaryKeptSeconds) {
        continue;
      }
      result.add(segment);
    }
    return result;
  }

  /// Union length of [input] in seconds.
  ///
  /// Always measures the union, never a raw sum, so a caller that forgets to
  /// normalize first cannot over-report the removed duration (SR-03). An
  /// invalid-only input measures `0` instead of throwing (B01-R3).
  static double totalSeconds(List<SilenceSegment> input) {
    var total = 0.0;
    for (final segment in union(input)) {
      total += segment.durationSeconds;
    }
    return total;
  }

  /// Applies the two guard amounts as **protected space inside** each confirmed
  /// silence (SR-02).
  ///
  /// The removal interval shrinks from both ends, so raising a guard can only
  /// *keep more* of the recording — it can never push the cut into speech.
  /// Growing the cut outwards is a different, explicitly named decision and is
  /// deliberately not offered here.
  ///
  /// An interval consumed entirely by its guards disappears instead of being
  /// clamped into a zero-length range. Callers should pass normalized input.
  static List<SilenceSegment> applyProtectedPadding(
    List<SilenceSegment> input, {
    required double paddingBefore,
    required double paddingAfter,
    required double totalDuration,
  }) {
    final bound = nonNegativeOrZero(totalDuration);
    final before = nonNegativeOrZero(paddingBefore);
    final after = nonNegativeOrZero(paddingAfter);

    final guarded = <SilenceSegment>[];
    for (final segment in input) {
      if (!segment.isValid) continue;
      final start = segment.startSeconds + before;
      final end = segment.endSeconds - after;
      final clampedStart = start < 0 ? 0.0 : (start > bound ? bound : start);
      final clampedEnd = end < 0 ? 0.0 : (end > bound ? bound : end);
      if (clampedEnd - clampedStart < kMinSilenceIntervalSeconds) continue;
      guarded.add(
        SilenceSegment(startSeconds: clampedStart, endSeconds: clampedEnd),
      );
    }

    return union(guarded);
  }
}
