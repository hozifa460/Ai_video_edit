import '../../../../core/utils/logger.dart';
import '../entities/adjustment_preset.dart';
import '../entities/adjustment_settings.dart';
import '../repositories/adjustment_repository.dart';

class ApplyAdjustmentsUseCase {
  final AdjustmentRepository _repository;

  ApplyAdjustmentsUseCase(this._repository);

  Future<void> execute({
    required String inputPath,
    required String outputPath,
    required AdjustmentSettings settings,
    required void Function(double) onProgress,
    bool isPreview = false,
  }) async {
    AppLogger().i('ApplyAdjustments: input=$inputPath, hasAdjustments=${settings.hasAnyAdjustment}');
    await _repository.applyAdjustments(
      inputPath: inputPath,
      outputPath: outputPath,
      settings: settings,
      onProgress: onProgress,
      isPreview: isPreview,
    );
  }
}

class PreviewFrameUseCase {
  final AdjustmentRepository _repository;

  PreviewFrameUseCase(this._repository);

  Future<String> execute(String inputPath, AdjustmentSettings settings) async {
    return _repository.extractPreviewFrame(inputPath: inputPath, settings: settings);
  }
}

class ExportAdjustedVideoUseCase {
  final AdjustmentRepository _repository;

  ExportAdjustedVideoUseCase(this._repository);

  Future<void> execute({
    required String inputPath,
    required String outputPath,
    required AdjustmentSettings settings,
    required String quality,
    required void Function(double) onProgress,
  }) async {
    AppLogger().i('ExportAdjusted: quality=$quality, hasAdjustments=${settings.hasAnyAdjustment}');
    await _repository.exportVideo(
      inputPath: inputPath,
      outputPath: outputPath,
      settings: settings,
      quality: quality,
      onProgress: onProgress,
    );
  }
}

class ApplyPresetUseCase {
  AdjustmentSettings execute(AdjustmentPreset preset) {
    return preset.settings;
  }
}

class ApplyLutUseCase {
  AdjustmentSettings execute(AdjustmentSettings settings, String lutPath) {
    return settings.copyWith(lutPath: lutPath);
  }
}
