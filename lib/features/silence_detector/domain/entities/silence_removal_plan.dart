import 'package:equatable/equatable.dart';
import '../services/interval_algebra.dart';
import 'silence_segment.dart';

/// The single canonical description of one silence-removal job.
///
/// Detection, the statistics widgets, the preview screen and the FFmpeg cut all
/// read this object, so "how much was removed" and "what actually gets cut"
/// cannot drift apart (SR-03).
///
/// Guarantees, for any input list:
/// * `removals` is sorted, finite, clamped to `[0, totalDurationSeconds]` and
///   pairwise non-overlapping
/// * `kept` is the complement of `removals` over `[0, totalDurationSeconds]`,
///   minus sub-120ms slivers at the two timeline boundaries (see
///   `IntervalAlgebra.complement`); those slivers are guard margins with no
///   video frames in them, so they are excluded from the cut as well
/// * `removedSeconds + keptSeconds == totalDurationSeconds` up to those
///   boundary slivers (at most 120ms at each edge)
/// * `0 <= removedSeconds <= totalDurationSeconds` and `removedRatio` is in `[0,1]`
///
/// `totalDurationSeconds` is the **probed video duration**, so a video whose
/// audio ends earlier keeps its picture tail instead of being clamped to the
/// audio length (SR-05).
class SilenceRemovalPlan extends Equatable {
  final double totalDurationSeconds;
  final List<SilenceSegment> removals;
  final List<SilenceSegment> kept;

  const SilenceRemovalPlan._({
    required this.totalDurationSeconds,
    required this.removals,
    required this.kept,
  });

  /// Normalizes [removals] against [totalDurationSeconds] and derives the kept
  /// ranges. Unusable input yields an empty, still-consistent plan rather than a
  /// throwing one.
  ///
  /// Both exposed lists are unmodifiable copies (B01-C1). Mutating
  /// `plan.removals` in place would desynchronize the statistics from `kept` and
  /// break the `removed + kept == total` invariant for every later reader, so
  /// the constructor is private and the only way to change a plan is to build a
  /// new one.
  factory SilenceRemovalPlan.build({
    required double totalDurationSeconds,
    required Iterable<SilenceSegment> removals,
  }) {
    final total = IntervalAlgebra.nonNegativeOrZero(totalDurationSeconds);
    final normalized = IntervalAlgebra.normalize(
      removals.toList(),
      totalDuration: total,
    );
    return SilenceRemovalPlan._(
      totalDurationSeconds: total,
      removals: List<SilenceSegment>.unmodifiable(normalized),
      kept: List<SilenceSegment>.unmodifiable(
        IntervalAlgebra.complement(normalized, totalDurationSeconds: total),
      ),
    );
  }

  double get removedSeconds => IntervalAlgebra.totalSeconds(removals);

  double get keptSeconds => IntervalAlgebra.totalSeconds(kept);

  /// Removed duration for Dart/FFmpeg statistics — explicit seconds → ms.
  Duration get removedDuration =>
      Duration(milliseconds: (removedSeconds * 1000).round());

  Duration get keptDuration =>
      Duration(milliseconds: (keptSeconds * 1000).round());

  Duration get totalDuration =>
      Duration(milliseconds: (totalDurationSeconds * 1000).round());

  /// Share of the timeline removed, in `[0,1]`. `0` when the timeline has no
  /// usable duration, so a failed probe cannot display a divide-by-zero or a
  /// value above 100%.
  double get removedRatio {
    if (totalDurationSeconds <= 0) return 0;
    final ratio = removedSeconds / totalDurationSeconds;
    if (ratio.isNaN) return 0;
    return ratio.clamp(0.0, 1.0);
  }

  double get removedPercent => removedRatio * 100;

  bool get hasRemovals => removals.isNotEmpty;

  /// True when nothing would be deleted.
  bool get isEmpty => removals.isEmpty;

  /// True when the whole timeline would be deleted.
  bool get removesEverything => totalDurationSeconds > 0 && kept.isEmpty;

  bool get isUsable => totalDurationSeconds > 0;

  /// Returns a plan whose removal list no longer contains the interval at
  /// [index] — the timeline's "keep this range" action. Statistics and the cut
  /// are both rebuilt from the result, so excluding an entry can never leave a
  /// stale sum behind.
  SilenceRemovalPlan withoutRemoval(int index) {
    if (index < 0 || index >= removals.length) return this;
    final remaining = removals.toList()..removeAt(index);
    return SilenceRemovalPlan.build(
      totalDurationSeconds: totalDurationSeconds,
      removals: remaining,
    );
  }

  @override
  List<Object?> get props => [totalDurationSeconds, removals, kept];
}
