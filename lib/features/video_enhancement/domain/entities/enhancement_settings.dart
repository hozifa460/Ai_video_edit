import 'package:equatable/equatable.dart';
import 'enhancement_plan.dart';

class EnhancementSettings extends Equatable {
  final EnhancementLevel level;
  final bool denoiseEnabled;
  final bool sharpenEnabled;
  final bool upscaleEnabled;
  final bool colorGradeEnabled;
  final bool audioEnhanceEnabled;
  final int targetWidth;
  final int targetHeight;
  final int qualityCrf;
  final String encodingPreset;

  const EnhancementSettings({
    this.level = EnhancementLevel.balanced,
    this.denoiseEnabled = true,
    this.sharpenEnabled = true,
    this.upscaleEnabled = true,
    this.colorGradeEnabled = true,
    this.audioEnhanceEnabled = true,
    this.targetWidth = 1920,
    this.targetHeight = 1080,
    this.qualityCrf = 18,
    this.encodingPreset = 'medium',
  });

  EnhancementSettings copyWith({
    EnhancementLevel? level,
    bool? denoiseEnabled,
    bool? sharpenEnabled,
    bool? upscaleEnabled,
    bool? colorGradeEnabled,
    bool? audioEnhanceEnabled,
    int? targetWidth,
    int? targetHeight,
    int? qualityCrf,
    String? encodingPreset,
  }) {
    return EnhancementSettings(
      level: level ?? this.level,
      denoiseEnabled: denoiseEnabled ?? this.denoiseEnabled,
      sharpenEnabled: sharpenEnabled ?? this.sharpenEnabled,
      upscaleEnabled: upscaleEnabled ?? this.upscaleEnabled,
      colorGradeEnabled: colorGradeEnabled ?? this.colorGradeEnabled,
      audioEnhanceEnabled: audioEnhanceEnabled ?? this.audioEnhanceEnabled,
      targetWidth: targetWidth ?? this.targetWidth,
      targetHeight: targetHeight ?? this.targetHeight,
      qualityCrf: qualityCrf ?? this.qualityCrf,
      encodingPreset: encodingPreset ?? this.encodingPreset,
    );
  }

  factory EnhancementSettings.fromPlan(EnhancementPlan plan) {
    final level = plan.level;
    final crf = switch (level) {
      EnhancementLevel.fast => 20,
      EnhancementLevel.balanced => 18,
      EnhancementLevel.quality => 16,
      EnhancementLevel.ultra => 14,
    };
    final preset = switch (level) {
      EnhancementLevel.fast => 'fast',
      EnhancementLevel.balanced => 'medium',
      EnhancementLevel.quality => 'slow',
      EnhancementLevel.ultra => 'veryslow',
    };

    return EnhancementSettings(
      level: level,
      denoiseEnabled: plan.willDenoise,
      sharpenEnabled: plan.willSharpen,
      upscaleEnabled: plan.willUpscale,
      colorGradeEnabled: plan.willColorGrade,
      audioEnhanceEnabled: plan.willEnhanceAudio,
      targetWidth: plan.analysis?.getUpscaleTarget().width.toInt() ?? 1920,
      targetHeight: plan.analysis?.getUpscaleTarget().height.toInt() ?? 1080,
      qualityCrf: crf,
      encodingPreset: preset,
    );
  }

  @override
  List<Object?> get props => [
    level,
    denoiseEnabled,
    sharpenEnabled,
    upscaleEnabled,
    colorGradeEnabled,
    audioEnhanceEnabled,
    targetWidth,
    targetHeight,
    qualityCrf,
    encodingPreset,
  ];
}