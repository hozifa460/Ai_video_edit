import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entities/detection_params.dart';
import '../../domain/entities/silence_segment.dart';
import '../../domain/services/interval_algebra.dart';

class FfmpegSilenceDatasource {
  /// IEEE-754 binary64 rounding steps that a minimum comparison depends on.
  ///
  /// Deciding `end - start >= min` reads three doubles out of text — `start`,
  /// `end` and `min` — and each carries up to half a unit in the last place of
  /// its own magnitude. The subtraction itself rounds once more. Four steps is
  /// therefore a *derived* upper bound on the arithmetic error, not a tuned
  /// constant: 3 parsed bounds + 1 rounding of the difference.
  ///
  /// Why the bound is applied to the magnitudes and not to the minimum alone:
  /// the error of `end - start` grows with where the interval sits on the
  /// timeline, because that is the magnitude the bounds were rounded at.
  /// `3600.02 - 3600.01` is `0.009999999999763531`, short of the limit by
  /// 2.4e-13s, while `0.02 - 0.01` is exactly `0.01`. A margin derived from
  /// `min` alone is therefore blind to it, and the same 10ms silence is
  /// accepted near zero and rejected an hour in (SR06-R3).
  static const int kBoundaryRoundingSteps = 4;

  /// Machine epsilon for IEEE-754 binary64, i.e. `2^-52`, the relative spacing
  /// between representable numbers.
  static const double _relativeUlp = 2.220446049250313e-16;

  /// The absolute numeric margin applied below a limit, for the largest
  /// magnitude among the given quantities.
  ///
  /// Exposed so a test can show the margin is orders of magnitude smaller than
  /// any duration the detector distinguishes.
  static double numericMarginFor(double scale) {
    final magnitude = IntervalAlgebra.nonNegativeOrZero(scale.abs());
    return magnitude * kBoundaryRoundingSteps * _relativeUlp;
  }

  /// The numeric margin for a comparison of `endSeconds - startSeconds` against
  /// [minSilenceDuration].
  ///
  /// Scaled by the largest of the three bounds, because that is the magnitude
  /// the parsed decimals were rounded at. Within the supported timeline this is
  /// invisible: at 24 hours it is 7.7e-11s, about one eight-thousandth of a
  /// single sample at 16kHz, and reaching one whole sample would need a
  /// timestamp around two thousand years out.
  ///
  /// Why not 1ms: an earlier revision subtracted a full millisecond, which is
  /// 10% of the smallest minimum and accepted a 9.5ms pause at a 10ms limit
  /// (SR06-R1). Sixteen samples of audio is real time, not a rounding error.
  static double numericMarginForInterval(
    double startSeconds,
    double endSeconds,
    double minSilenceDuration,
  ) {
    var scale = minSilenceDuration.isFinite ? minSilenceDuration.abs() : 0.0;
    for (final bound in [startSeconds, endSeconds]) {
      if (bound.isFinite && bound.abs() > scale) scale = bound.abs();
    }
    return numericMarginFor(scale);
  }

  Future<List<SilenceSegment>> detectSilence({
    required String audioPath,
    required DetectionParams params,
    double? totalDuration,
  }) async {
    // One accurate pass is sufficient: any audio below `threshold - 10dB` is
    // already below `threshold`, so the old second pass could only re-detect
    // the same or shorter silences while doubling decode time. The user's
    // threshold and minimum are used directly (SR-06).
    final detected = await _runPass(
      audioPath,
      params,
      useRms: false,
      totalDuration: totalDuration,
    );

    return _mergeResults(
      detected,
      minSilenceDuration: params.minSilenceDuration,
    );
  }

  /// True when a raw silence of [lengthSeconds] satisfies the configured
  /// [minSilenceDuration].
  ///
  /// Inclusive at the limit, plus only the numeric headroom of
  /// [kBoundaryRoundingSteps] below it. A length genuinely below the limit is
  /// rejected no matter how close it is: 9.5ms does not satisfy 10ms (SR06-R1).
  ///
  /// **This form has lost the bounds it came from** and therefore cannot judge
  /// where on the timeline the interval sat; it scales the margin by
  /// `max(|length|, min)`. Use [satisfiesMinimumInterval] wherever the bounds
  /// are known, which is every filtering path in this class.
  ///
  /// Exposed and pure so the boundary can be pinned in tests without a media
  /// engine, and kept bound-free so existing callers and acceptance checks keep
  /// their meaning.
  static bool satisfiesMinimumSilence(
    double lengthSeconds,
    double minSilenceDuration,
  ) {
    if (!lengthSeconds.isFinite) return false;
    final min = IntervalAlgebra.nonNegativeOrZero(minSilenceDuration);
    if (min <= 0) return true;
    final scale = lengthSeconds.abs() > min ? lengthSeconds.abs() : min;
    return lengthSeconds >= min - numericMarginFor(scale);
  }

  /// The comparison contract for a parsed interval: true when
  /// `endSeconds - startSeconds` satisfies [minSilenceDuration].
  ///
  /// The margin is scaled by the bounds themselves, so moving an exact decimal
  /// silence along the timeline cannot change the verdict: a 10ms silence is a
  /// 10ms silence whether it is logged at `[0.01,0.02]`, `[9.98,9.99]` or
  /// `[3600.01,3600.02]`, and a 9.5ms silence is rejected at all three
  /// positions (SR06-R3).
  static bool satisfiesMinimumInterval(
    double startSeconds,
    double endSeconds,
    double minSilenceDuration,
  ) {
    if (!startSeconds.isFinite || !endSeconds.isFinite) return false;
    final min = IntervalAlgebra.nonNegativeOrZero(minSilenceDuration);
    if (min <= 0) return true;
    final margin = numericMarginForInterval(startSeconds, endSeconds, min);
    return (endSeconds - startSeconds) >= min - margin;
  }

  Future<List<SilenceSegment>> _runPass(
    String audioPath,
    DetectionParams params, {
    bool useRms = false,
    double? totalDuration,
  }) async {
    final rmsFlag = useRms ? ':m=1' : '';
    final command =
        '-i "$audioPath" -af silencedetect=noise=${params.ffmpegNoiseLevel}dB:d=${params.minSilenceDuration}$rmsFlag -f null -';

    AppLogger().i('Silence detect pass: $command');

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      AppLogger().e('Pass failed: $logs');
      throw Exception('Silence detection failed: $logs');
    }

    final logs = await session.getAllLogsAsString();
    return _rejectBelowMinimum(
      _parseSilenceOutput(logs ?? '', fallbackEnd: totalDuration),
      params.minSilenceDuration,
    );
  }

  /// Drops raw silences shorter than the configured minimum.
  ///
  /// A second enforcement of the same contract, on top of `silencedetect`'s own
  /// `d=` option: the log parser and the synthesized trailing-silence interval
  /// can both produce a range the user excluded.
  ///
  /// It compares through [satisfiesMinimumInterval] rather than through the bare
  /// duration, because this is the one place that still holds the bounds the
  /// comparison depends on. Both enforcement points — here after the pass, and
  /// again in `_mergeResults` before union — go through this same method, so a
  /// silence that survives the first check is never dropped by the second
  /// (SR06-R3).
  ///
  /// This is a **detection** limit on raw silences only. It must never be
  /// applied to the final removal, because the speech guards and breathing
  /// protection legitimately shrink an accepted silence below the minimum
  /// (SR-02); that decision lives downstream in the repository.
  List<SilenceSegment> _rejectBelowMinimum(
    List<SilenceSegment> segments,
    double minSilenceDuration,
  ) {
    return segments
        .where(
          (s) =>
              s.isValid &&
              satisfiesMinimumInterval(
                s.startSeconds,
                s.endSeconds,
                minSilenceDuration,
              ),
        )
        .toList();
  }

  List<SilenceSegment> _mergeResults(
    List<SilenceSegment> allResults, {
    required double minSilenceDuration,
  }) {
    // Overlap/touching only. This previously filled gaps up to 150ms, then a
    // revision passed a 20ms "sample-boundary tolerance"; both deleted audio
    // that nothing had classified as silence (SR-01, B01-R2). A 10ms gap is 160
    // samples at 16kHz and can hold a consonant onset, so no positive gap is
    // absorbed here. The bound is the widest observed end only because `union`
    // takes a duration for clamping.
    return IntervalAlgebra.normalize(
      _rejectBelowMinimum(allResults, minSilenceDuration),
      totalDuration: _maxObservedEnd(allResults),
      minLengthSeconds: 0,
    );
  }

  double _maxObservedEnd(List<SilenceSegment> segments) {
    var max = 0.0;
    for (final segment in segments) {
      if (segment.endSeconds.isFinite && segment.endSeconds > max) {
        max = segment.endSeconds;
      }
    }
    return max;
  }

  List<SilenceSegment> _parseSilenceOutput(String logs, {double? fallbackEnd}) {
    final segments = <SilenceSegment>[];
    final lines = logs.split('\n');

    double? currentStart;

    for (final line in lines) {
      if (line.contains('silence_start:')) {
        final parts = line.split('silence_start:');
        if (parts.length > 1) {
          currentStart = double.tryParse(parts[1].trim());
        }
      } else if (line.contains('silence_end:')) {
        final parts = line.split('silence_end:');
        double? currentEnd;
        if (parts.length > 1) {
          const pattern = r'([\d.]+)';
          final regex = RegExp(pattern);
          final match = regex.firstMatch(parts[1].trim());
          if (match != null) {
            final group = match.group(1);
            if (group != null) {
              currentEnd = double.tryParse(group);
            }
          }
        }

        if (currentStart != null && currentEnd != null) {
          // `double.tryParse` accepts "NaN"/"Infinity"; a non-finite or
          // inverted pair must never reach the pipeline (SR-03).
          final parsedStart = IntervalAlgebra.finiteOr(
            currentStart,
            fallback: double.nan,
          );
          final parsedEnd = IntervalAlgebra.finiteOr(
            currentEnd,
            fallback: double.nan,
          );
          if (parsedStart.isFinite && parsedEnd.isFinite) {
            segments.add(
              SilenceSegment(startSeconds: parsedStart, endSeconds: parsedEnd),
            );
          }
          currentStart = null;
        }
      }
    }

    // Trailing silence: ffmpeg emits a final silence_start with no matching
    // silence_end when the stream ends mid-silence. Close it at the window end so
    // end-of-video silence is detected too.
    //
    // The range is closed whenever it is genuinely well formed — finite bounds
    // inside the window and a positive length. There is no separate acceptance
    // window: an earlier revision required 50ms here, which silently dropped a
    // 20ms trailing silence at a 10ms minimum even though it was longer than the
    // user's own limit (SR06-R2). The configured minimum is the only acceptance
    // policy, and `_rejectBelowMinimum` applies it after parsing.
    //
    // Non-finite input falls back to NaN rather than 0: substituting 0 would
    // invent a full-length silence out of an unreadable bound (SR-03).
    if (currentStart != null && fallbackEnd != null) {
      final parsedStart = IntervalAlgebra.finiteOr(
        currentStart,
        fallback: double.nan,
      );
      final parsedEnd = IntervalAlgebra.finiteOr(
        fallbackEnd,
        fallback: double.nan,
      );
      final trailing = SilenceSegment(
        startSeconds: parsedStart,
        endSeconds: parsedEnd,
      );
      if (trailing.isValid && trailing.startSeconds >= 0) {
        segments.add(trailing);
      }
    }

    return segments;
  }
}
