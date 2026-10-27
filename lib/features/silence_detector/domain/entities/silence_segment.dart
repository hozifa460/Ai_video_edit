import 'package:equatable/equatable.dart';

/// A half-open time range `[startSeconds, endSeconds)` in seconds.
///
/// The feature works on **seconds** because FFmpeg filtergraph arguments are
/// float seconds; Dart `Duration` values are derived explicitly in
/// milliseconds at the UI/statistics boundary (see `SilenceRemovalPlan`).
class SilenceSegment extends Equatable {
  final double startSeconds;
  final double endSeconds;

  const SilenceSegment({required this.startSeconds, required this.endSeconds});

  double get durationSeconds => endSeconds - startSeconds;

  /// True when both bounds are real numbers (no NaN/Infinity).
  bool get hasFiniteBounds => startSeconds.isFinite && endSeconds.isFinite;

  /// True when the range can describe a real cut: finite, non-empty, and not
  /// inverted. Used to drop degenerate input before it reaches FFmpeg.
  bool get isValid => hasFiniteBounds && startSeconds < endSeconds;

  /// True when [seconds] falls inside this range (both bounds inclusive).
  bool contains(double seconds) =>
      seconds >= startSeconds && seconds <= endSeconds;

  /// True when this range shares any time with [other].
  bool overlaps(SilenceSegment other) =>
      startSeconds < other.endSeconds && other.startSeconds < endSeconds;

  SilenceSegment copyWith({double? startSeconds, double? endSeconds}) {
    return SilenceSegment(
      startSeconds: startSeconds ?? this.startSeconds,
      endSeconds: endSeconds ?? this.endSeconds,
    );
  }

  @override
  List<Object?> get props => [startSeconds, endSeconds];
}
