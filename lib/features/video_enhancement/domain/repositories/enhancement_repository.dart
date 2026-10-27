import '../entities/video_analysis_result.dart';
import '../entities/enhancement_plan.dart';
import '../entities/enhancement_settings.dart';

abstract class EnhancementRepository {
  Future<VideoAnalysisResult> analyzeVideo(String videoPath);
  Future<EnhancementPlan> buildEnhancementPlan(
    VideoAnalysisResult analysis,
    EnhancementLevel level,
  );
  Future<String> generatePreviewFrame(
    String videoPath,
    Duration timestamp,
    EnhancementSettings settings,
  );
  Stream<EnhancementProgress> enhanceVideo(
    String inputPath,
    EnhancementSettings settings,
  );
  Future<VideoMetadata?> getVideoMetadata(String videoPath);
}

class EnhancementProgress {
  final int currentStage;
  final int totalStages;
  final String stageName;
  final double progress;
  final Duration? estimatedRemaining;
  final int framesProcessed;
  final int totalFrames;

  const EnhancementProgress({
    required this.currentStage,
    required this.totalStages,
    required this.stageName,
    required this.progress,
    this.estimatedRemaining,
    this.framesProcessed = 0,
    this.totalFrames = 0,
  });

  double get overallProgress => totalStages > 0 
    ? (currentStage + progress) / totalStages 
    : 0.0;
}