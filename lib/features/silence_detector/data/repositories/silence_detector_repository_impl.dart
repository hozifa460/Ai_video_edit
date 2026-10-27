import '../../../../core/errors/failures.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/detection_params.dart';
import '../../domain/entities/media_timeline.dart';
import '../../domain/entities/silence_detection_blocker.dart';
import '../../domain/entities/silence_removal_plan.dart';
import '../../domain/entities/silence_segment.dart';
import '../../domain/repositories/silence_detector_repository.dart';
import '../../domain/services/interval_algebra.dart';
import '../datasources/ffmpeg_silence_datasource.dart';
import '../services/breathing_protection_service.dart';
import '../services/vad_service.dart';

class SilenceDetectorRepositoryImpl implements SilenceDetectorRepository {
  final FfmpegSilenceDatasource _datasource;
  final VadService _vadService;
  final BreathingProtectionService _breathingService;

  SilenceDetectorRepositoryImpl({
    FfmpegSilenceDatasource? datasource,
    VadService? vadService,
    BreathingProtectionService? breathingService,
  }) : _datasource = datasource ?? FfmpegSilenceDatasource(),
       _vadService = vadService ?? VadService(),
       _breathingService = breathingService ?? BreathingProtectionService();

  @override
  Future<Result<SilenceRemovalPlan>> buildRemovalPlan({
    required String audioPath,
    required DetectionParams params,
    required MediaTimeline timeline,
  }) async {
    // One shared, ordered reason for every "cannot detect" case, so the screen and
    // this layer never report different causes for the same timeline (B01-F2).
    final blocker = SilenceDetectionGate.blockerFor(timeline);
    if (blocker != null) {
      final message = SilenceDetectionGate.messageFor(blocker);
      AppLogger().e('Silence detection refused: $message');
      return AppError(SilenceDetectionFailure(message: message));
    }

    // Detection runs on the extracted audio, so every bound here is an
    // audio-timeline bound taken from the intersection with the video. The
    // picture tail past that intersection is preserved by the video-timeline
    // complement in SilenceRemovalPlan.
    final windowEnd = timeline.detectionWindowEndSeconds;

    try {
      var segments = await _datasource.detectSilence(
        audioPath: audioPath,
        params: params,
        totalDuration: windowEnd,
      );

      // Normalize before any filter runs so VAD and breathing protection see
      // sorted, disjoint, finite intervals regardless of what the log parser
      // produced (SR-03).
      segments = IntervalAlgebra.normalize(segments, totalDuration: windowEnd);

      if (params.useVad) {
        segments = await _vadService.refineSilence(audioPath, segments, params);
        segments = IntervalAlgebra.normalize(
          segments,
          totalDuration: windowEnd,
        );
      }

      // Guards shrink each confirmed silence from the inside. They are applied
      // before breathing protection so a short pause keeps its edges intact
      // (SR-02). A leftover shorter than 50ms is no longer worth a cut.
      segments = applyPadding(
        segments,
        paddingBefore: params.paddingBefore,
        paddingAfter: params.paddingAfter,
        totalDuration: windowEnd,
      );

      if (params.useBreathingProtection) {
        segments = _breathingService.protect(
          segments,
          minSilenceDuration: params.minSilenceDuration,
          totalDuration: windowEnd,
        );
        segments = IntervalAlgebra.normalize(
          segments,
          totalDuration: windowEnd,
        );
      }

      // Move the result onto the video timeline before anything measures or
      // cuts it. The shift is signed and applied before clipping, so audio that
      // begins before the video contributes its in-video part (B01-R1).
      final onVideoTimeline = timeline.audioToVideoTimeline(segments);

      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: timeline.videoDurationSeconds,
        removals: onVideoTimeline,
      );

      AppLogger().i(
        'Removal plan: ${plan.removals.length} intervals, '
        'removed=${plan.removedSeconds.toStringAsFixed(3)}s of '
        '${plan.totalDurationSeconds}s, kept=${plan.kept.length} intervals',
      );
      return Success(plan);
    } catch (e, stack) {
      AppLogger().e('Silence detection failed', e, stack);
      return AppError(SilenceDetectionFailure(message: e.toString()));
    }
  }

  /// Union-only merge exposed for callers and tests that need the audio-window
  /// normalization on its own. Overlap/touching only, never a gap policy
  /// (SR-01, SR-19, B01-R2).
  List<SilenceSegment> mergeOverlappingSegments(List<SilenceSegment> segments) {
    return IntervalAlgebra.union(segments);
  }

  /// Shortest guarded remainder this pipeline will still cut: 50ms.
  ///
  /// Below one video frame at any normal rate the cut is visual noise rather
  /// than content removal, and expanding it to reach a minimum would delete
  /// speech. The floor is applied only when a guard actually shrinks the
  /// segment; an unguarded detection follows the user's `minSilenceDuration`.
  static const double kMinProtectedSegmentSeconds = 0.05;

  /// Representation headroom for decimal bounds such as `1.1 - 1.05`.
  ///
  /// This is not a media-policy tolerance: 1ns is below one sample at any
  /// plausible audio rate. It only prevents an exact 50ms remainder from being
  /// discarded because binary64 stores it as 49.99999999999999ms.
  static const double _durationComparisonEpsilon = 1e-9;

  /// A silence bound this close to a timeline edge is treated as **on** the
  /// edge: there is no neighbouring speech to protect there.
  static const double kTimelineBoundarySeconds = 0.05;

  /// Shrinks every silence segment by the requested speech guards.
  ///
  /// [paddingBefore] and [paddingAfter] are **protected space inside** the
  /// confirmed silence, never extra deletion outside it:
  /// `[start + before, end - after]`. Growing the cut outwards is exactly the
  /// inverted-padding bug: it removes the first/last part of a spoken word.
  ///
  /// Segments whose guarded length is under [kMinProtectedSegmentSeconds] are
  /// discarded (including `end <= start`), so a guard that consumes a short
  /// pause cannot leave a zero-length or sub-frame cut for FFmpeg.
  ///
  /// The 50ms floor belongs to the guard: it only applies once a guard actually
  /// shrinks the segment. An unguarded detection is the user's minimum-silence
  /// verdict (SR-06) and must survive even at the 10ms setting; dropping it
  /// here would silently override the value passed to `silencedetect`.
  List<SilenceSegment> applyPadding(
    List<SilenceSegment> segments, {
    required double paddingBefore,
    required double paddingAfter,
    required double totalDuration,
  }) {
    final bound = IntervalAlgebra.nonNegativeOrZero(totalDuration);
    final before = IntervalAlgebra.nonNegativeOrZero(paddingBefore);
    final after = IntervalAlgebra.nonNegativeOrZero(paddingAfter);
    final hasGuard = before > 0 || after > 0;

    final guarded = <SilenceSegment>[];
    for (final segment in segments) {
      if (!segment.isValid) continue;

      // Guards protect *neighbouring speech*. A silence that already touches
      // `t=0` or the end of the window has no speech on that side, so applying
      // the guard there would only invent an 80-160ms "speech" sliver at the
      // boundary — a range the video stream may not even contain a frame in.
      final start =
          (segment.startSeconds > kTimelineBoundarySeconds
                  ? segment.startSeconds + before
                  : 0.0)
              .clamp(0.0, bound)
              .toDouble();
      final end =
          (segment.endSeconds < bound - kTimelineBoundarySeconds
                  ? segment.endSeconds - after
                  : bound)
              .clamp(0.0, bound)
              .toDouble();

      if (end <= start) continue;
      if (hasGuard &&
          end - start <
              kMinProtectedSegmentSeconds - _durationComparisonEpsilon) {
        continue;
      }

      guarded.add(SilenceSegment(startSeconds: start, endSeconds: end));
    }

    return IntervalAlgebra.union(guarded);
  }
}
