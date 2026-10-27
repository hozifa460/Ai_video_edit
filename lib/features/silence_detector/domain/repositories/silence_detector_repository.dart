import '../../../../core/utils/result.dart';
import '../entities/detection_params.dart';
import '../entities/media_timeline.dart';
import '../entities/silence_removal_plan.dart';

abstract class SilenceDetectorRepository {
  /// Produces the canonical removal plan for one file.
  ///
  /// [timeline] must carry the probed video duration and audio offset; the
  /// waveform is never a source of timing here (SR-05). The returned plan is
  /// the only object the UI statistics, the preview screen and the FFmpeg cut
  /// are allowed to read (SR-03).
  Future<Result<SilenceRemovalPlan>> buildRemovalPlan({
    required String audioPath,
    required DetectionParams params,
    required MediaTimeline timeline,
  });
}
