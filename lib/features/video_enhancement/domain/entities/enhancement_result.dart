import 'video_analysis_result.dart';

class EnhancementResult {
  final String outputPath;
  final VideoMetadata originalMetadata;
  final VideoMetadata? enhancedMetadata;
  final Duration processingTime;
  final bool success;
  final String? errorMessage;
  final List<EnhancementStageResult> stages;

  const EnhancementResult({
    required this.outputPath,
    required this.originalMetadata,
    this.enhancedMetadata,
    required this.processingTime,
    required this.success,
    this.errorMessage,
    this.stages = const [],
  });

  factory EnhancementResult.success({
    required String outputPath,
    required VideoMetadata originalMetadata,
    VideoMetadata? enhancedMetadata,
    required Duration processingTime,
    List<EnhancementStageResult> stages = const [],
  }) {
    return EnhancementResult(
      outputPath: outputPath,
      originalMetadata: originalMetadata,
      enhancedMetadata: enhancedMetadata,
      processingTime: processingTime,
      success: true,
      stages: stages,
    );
  }

  factory EnhancementResult.failure({
    required String outputPath,
    required VideoMetadata originalMetadata,
    required String errorMessage,
    required Duration processingTime,
  }) {
    return EnhancementResult(
      outputPath: outputPath,
      originalMetadata: originalMetadata,
      processingTime: processingTime,
      success: false,
      errorMessage: errorMessage,
    );
  }

  int get originalFileSizeMb => (originalMetadata.fileSizeBytes / 1024 / 1024).round();
  int get enhancedFileSizeMb => enhancedMetadata != null 
    ? (enhancedMetadata!.fileSizeBytes / 1024 / 1024).round() 
    : 0;

  double get improvementRatio => enhancedMetadata != null
    ? (enhancedMetadata!.width * enhancedMetadata!.height) / 
      (originalMetadata.width * originalMetadata.height)
    : 1.0;
}

class EnhancementStageResult {
  final String name;
  final Duration duration;
  final bool success;
  final String? message;

  const EnhancementStageResult({
    required this.name,
    required this.duration,
    required this.success,
    this.message,
  });
}

class PreviewFrame {
  final int frameIndex;
  final Duration timestamp;
  final String originalPath;
  final String? enhancedPath;
  final bool isEnhanced;

  const PreviewFrame({
    required this.frameIndex,
    required this.timestamp,
    required this.originalPath,
    this.enhancedPath,
    this.isEnhanced = false,
  });

  PreviewFrame copyWith({
    int? frameIndex,
    Duration? timestamp,
    String? originalPath,
    String? enhancedPath,
    bool? isEnhanced,
  }) {
    return PreviewFrame(
      frameIndex: frameIndex ?? this.frameIndex,
      timestamp: timestamp ?? this.timestamp,
      originalPath: originalPath ?? this.originalPath,
      enhancedPath: enhancedPath ?? this.enhancedPath,
      isEnhanced: isEnhanced ?? this.isEnhanced,
    );
  }
}