import 'dart:io';
import '../../domain/entities/video_analysis_result.dart';
import '../../domain/entities/enhancement_plan.dart';
import '../../domain/entities/enhancement_settings.dart';
import '../../domain/entities/enhancement_result.dart';
import '../../domain/repositories/enhancement_repository.dart';
import '../datasources/video_analyzer_datasource.dart';
import '../datasources/ffmpeg_enhancement_datasource.dart';
import '../datasources/preview_generator_datasource.dart';

class EnhancementRepositoryImpl implements EnhancementRepository {
  final VideoAnalyzerDatasource _analyzer = VideoAnalyzerDatasource();
  final FfmpegEnhancementDatasource _enhancer = FfmpegEnhancementDatasource();
  final PreviewGeneratorDatasource _previewGenerator = PreviewGeneratorDatasource();

  @override
  Future<VideoAnalysisResult> analyzeVideo(String videoPath) async {
    final file = File(videoPath);
    if (!await file.exists()) {
      throw Exception('Input video file does not exist: $videoPath');
    }
    return _analyzer.analyzeVideo(videoPath);
  }

  @override
  Future<EnhancementPlan> buildEnhancementPlan(
    VideoAnalysisResult analysis,
    EnhancementLevel level,
  ) async {
    return EnhancementPlan.fromAnalysis(analysis, level);
  }

  @override
  Future<String> generatePreviewFrame(
    String videoPath,
    Duration timestamp,
    EnhancementSettings settings,
  ) async {
    final preview = await _previewGenerator.generateSinglePreview(
      videoPath: videoPath,
      timestamp: timestamp,
      settings: settings,
    );

    if (preview?.enhancedPath == null) {
      throw Exception('Failed to generate preview frame');
    }

    return preview!.enhancedPath!;
  }

  @override
  Stream<EnhancementProgress> enhanceVideo(
    String inputPath,
    EnhancementSettings settings,
  ) async* {
    final file = File(inputPath);
    if (!await file.exists()) {
      throw Exception('Input video file does not exist: $inputPath');
    }

    // The datasource generates its own unique output path.
    yield* _enhancer.enhanceVideo(
      inputPath: inputPath,
      settings: settings,
      totalDurationMs: 60000,
    );

    yield EnhancementProgress(
      currentStage: 1,
      totalStages: 1,
      stageName: 'Complete',
      progress: 1.0,
    );
  }

  @override
  Future<VideoMetadata?> getVideoMetadata(String videoPath) async {
    try {
      final result = await analyzeVideo(videoPath);
      return result.metadata;
    } catch (e) {
      return null;
    }
  }

  Future<String> enhanceVideoDirect({
    required String inputPath,
    required EnhancementSettings settings,
  }) async {
    return _enhancer.enhanceVideoDirect(
      inputPath: inputPath,
      settings: settings,
    );
  }

  Future<List<PreviewFrame>> generatePreviewFrames({
    required String videoPath,
    required Duration videoDuration,
    required EnhancementSettings settings,
  }) async {
    return _previewGenerator.generatePreviewFrames(
      videoPath: videoPath,
      videoDuration: videoDuration,
      settings: settings,
    );
  }
}