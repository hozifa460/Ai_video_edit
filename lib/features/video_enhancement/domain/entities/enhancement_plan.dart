import 'video_analysis_result.dart';

enum EnhancementLevel {
  fast,
  balanced,
  quality,
  ultra,
}

class EnhancementAction {
  final String name;
  final String description;
  final bool isEnabled;
  final String filter;

  const EnhancementAction({
    required this.name,
    required this.description,
    required this.isEnabled,
    required this.filter,
  });
}

class EnhancementPlan {
  final EnhancementLevel level;
  final List<EnhancementAction> actions;
  final bool willUpscale;
  final bool willDenoise;
  final bool willSharpen;
  final bool willColorGrade;
  final bool willEnhanceAudio;
  final int estimatedDurationSeconds;
  final int estimatedOutputSizeMb;
  final VideoAnalysisResult? analysis;

  const EnhancementPlan({
    required this.level,
    required this.actions,
    required this.willUpscale,
    required this.willDenoise,
    required this.willSharpen,
    required this.willColorGrade,
    required this.willEnhanceAudio,
    required this.estimatedDurationSeconds,
    required this.estimatedOutputSizeMb,
    this.analysis,
  });

  factory EnhancementPlan.fromAnalysis(
    VideoAnalysisResult analysis,
    EnhancementLevel level,
  ) {
    final actions = <EnhancementAction>[];
    final metadata = analysis.metadata;
    final quality = analysis.quality;

    if (quality.noiseLevel > 0.3) {
      actions.add(const EnhancementAction(
        name: 'Noise Reduction',
        description: 'Remove noise and grain from video',
        isEnabled: true,
        filter: 'hqdn3d',
      ));
    }

    if (quality.brightness < 0.3) {
      actions.add(const EnhancementAction(
        name: 'Shadow Recovery',
        description: 'Lift dark areas and reveal detail',
        isEnabled: true,
        filter: 'curves',
      ));
    } else if (quality.brightness > 0.8) {
      actions.add(const EnhancementAction(
        name: 'Highlight Recovery',
        description: 'Restore blown highlights',
        isEnabled: true,
        filter: 'curves',
      ));
    }

    if (quality.contrast < 0.5) {
      actions.add(const EnhancementAction(
        name: 'Contrast Enhancement',
        description: 'Add depth and dimension',
        isEnabled: true,
        filter: 'curves',
      ));
    }

    if (quality.saturation < 0.6) {
      actions.add(const EnhancementAction(
        name: 'Color Enhancement',
        description: 'Boost saturation and vibrance',
        isEnabled: true,
        filter: 'eq',
      ));
    }

    if (quality.blurLevel > 0.4) {
      actions.add(const EnhancementAction(
        name: 'Sharpening',
        description: 'Enhance edge definition',
        isEnabled: true,
        filter: 'unsharp',
      ));
    }

    if (metadata.needsUpscaling) {
      actions.add(const EnhancementAction(
        name: 'Upscaling',
        description: 'Increase resolution to HD',
        isEnabled: true,
        filter: 'scale',
      ));
    }

    if (metadata.audioBitrate < 128000 && metadata.hasAudio) {
      actions.add(const EnhancementAction(
        name: 'Audio Enhancement',
        description: 'Improve audio quality',
        isEnabled: true,
        filter: 'afftdn+loudnorm',
      ));
    }

    final baseDuration = metadata.duration.inSeconds;
    final scaleFactor = switch (level) {
      EnhancementLevel.fast => 0.5,
      EnhancementLevel.balanced => 1.0,
      EnhancementLevel.quality => 2.0,
      EnhancementLevel.ultra => 3.0,
    };

    final upscaleFactor = metadata.needsUpscaling ? 1.5 : 1.0;
    final estimatedSeconds = (baseDuration * scaleFactor * upscaleFactor).round();

    final baseSizeMb = (metadata.fileSizeBytes / 1024 / 1024).round();
    final sizeFactor = level == EnhancementLevel.ultra ? 3.0 : (level == EnhancementLevel.quality ? 2.0 : 1.5);
    final estimatedSizeMb = (baseSizeMb * sizeFactor).round();

    return EnhancementPlan(
      level: level,
      actions: actions,
      willUpscale: metadata.needsUpscaling,
      willDenoise: quality.noiseLevel > 0.3,
      willSharpen: quality.blurLevel > 0.4,
      willColorGrade: quality.saturation < 0.6 || quality.contrast < 0.5,
      willEnhanceAudio: metadata.hasAudio && metadata.audioBitrate < 128000,
      estimatedDurationSeconds: estimatedSeconds,
      estimatedOutputSizeMb: estimatedSizeMb,
      analysis: analysis,
    );
  }

  String get levelLabel => switch (level) {
    EnhancementLevel.fast => 'Fast Fix',
    EnhancementLevel.balanced => 'Balanced',
    EnhancementLevel.quality => 'Quality Max',
    EnhancementLevel.ultra => 'Ultra',
  };
}