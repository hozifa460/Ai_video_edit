import '../entities/adjustment_settings.dart';

abstract class AdjustmentRepository {
  Future<String> buildFilterChain(AdjustmentSettings settings);
  Future<void> applyAdjustments({
    required String inputPath,
    required String outputPath,
    required AdjustmentSettings settings,
    required void Function(double) onProgress,
    bool isPreview,
  });
  Future<String> extractPreviewFrame({
    required String inputPath,
    required AdjustmentSettings settings,
  });
  Future<void> exportVideo({
    required String inputPath,
    required String outputPath,
    required AdjustmentSettings settings,
    required String quality,
    required void Function(double) onProgress,
  });
  Future<void> cancelProcessing();
}
