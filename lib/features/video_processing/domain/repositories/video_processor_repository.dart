import '../../../../core/utils/result.dart';
import '../../../../core/enums/export_quality.dart';
import '../entities/export_params.dart';
import '../../../silence_detector/domain/entities/detection_params.dart';
import '../../../silence_detector/domain/entities/silence_removal_plan.dart';

typedef ProcessingProgressCallback =
    void Function(double progress, String status);

abstract class VideoProcessorRepository {
  /// Cuts [videoPath] according to [plan].
  ///
  /// The plan carries both the removals and their complement over the probed
  /// video timeline, so this layer no longer recomputes a timeline of its own
  /// and cannot cut a different range from the one that was measured (SR-03,
  /// SR-05).
  Future<Result<String>> processVideo({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required ExportQuality quality,
    SmartZoomConfig? smartZoom,
    required ProcessingProgressCallback onProgress,
  });

  Future<Result<ExportParams>> exportVideo({
    required String sourcePath,
    required String outputPath,
    required String format,
    required ExportQuality quality,
    ProcessingProgressCallback? onProgress,
  });
}
