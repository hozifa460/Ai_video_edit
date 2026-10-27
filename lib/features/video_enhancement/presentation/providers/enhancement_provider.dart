import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/video_analysis_result.dart';
import '../../domain/entities/enhancement_plan.dart';
import '../../domain/entities/enhancement_settings.dart';
import '../../domain/entities/enhancement_result.dart';
import '../../domain/repositories/enhancement_repository.dart';
import '../../data/datasources/video_analyzer_datasource.dart';
import '../../data/datasources/ffmpeg_enhancement_datasource.dart';
import '../../data/datasources/preview_generator_datasource.dart';

enum EnhancementScreen {
  import,
  analysis,
  plan,
  preview,
  processing,
  result,
}

class EnhancementState {
  final EnhancementScreen currentScreen;
  final String? videoPath;
  final VideoAnalysisResult? analysis;
  final EnhancementPlan? plan;
  final EnhancementSettings settings;
  final EnhancementProgress? progress;
  final EnhancementResult? result;
  final List<PreviewFrame> previewFrames;
  final int selectedPreviewIndex;
  final bool isProcessing;
  final String? error;

  const EnhancementState({
    this.currentScreen = EnhancementScreen.import,
    this.videoPath,
    this.analysis,
    this.plan,
    this.settings = const EnhancementSettings(),
    this.progress,
    this.result,
    this.previewFrames = const [],
    this.selectedPreviewIndex = 0,
    this.isProcessing = false,
    this.error,
  });

  EnhancementState copyWith({
    EnhancementScreen? currentScreen,
    String? videoPath,
    VideoAnalysisResult? analysis,
    EnhancementPlan? plan,
    EnhancementSettings? settings,
    EnhancementProgress? progress,
    EnhancementResult? result,
    List<PreviewFrame>? previewFrames,
    int? selectedPreviewIndex,
    bool? isProcessing,
    String? error,
  }) {
    return EnhancementState(
      currentScreen: currentScreen ?? this.currentScreen,
      videoPath: videoPath ?? this.videoPath,
      analysis: analysis ?? this.analysis,
      plan: plan ?? this.plan,
      settings: settings ?? this.settings,
      progress: progress ?? this.progress,
      result: result ?? this.result,
      previewFrames: previewFrames ?? this.previewFrames,
      selectedPreviewIndex: selectedPreviewIndex ?? this.selectedPreviewIndex,
      isProcessing: isProcessing ?? this.isProcessing,
      error: error,
    );
  }
}

class EnhancementNotifier extends Notifier<EnhancementState> {
  final VideoAnalyzerDatasource _analyzer = VideoAnalyzerDatasource();
  final FfmpegEnhancementDatasource _enhancer = FfmpegEnhancementDatasource();
  final PreviewGeneratorDatasource _previewGenerator = PreviewGeneratorDatasource();

  @override
  EnhancementState build() => const EnhancementState();

  void setVideoPath(String path) {
    state = state.copyWith(videoPath: path, currentScreen: EnhancementScreen.analysis);
  }

  Future<void> analyzeVideo() async {
    if (state.videoPath == null) return;

    state = state.copyWith(isProcessing: true, error: null);

    try {
      final result = await _analyzer.analyzeVideo(state.videoPath!);
      final plan = EnhancementPlan.fromAnalysis(result, state.settings.level);
      
      state = state.copyWith(
        analysis: result,
        plan: plan,
        settings: EnhancementSettings.fromPlan(plan),
        currentScreen: EnhancementScreen.plan,
        isProcessing: false,
      );
    } catch (e) {
      state = state.copyWith(
        isProcessing: false,
        error: 'Analysis failed: $e',
      );
    }
  }

  void setEnhancementLevel(EnhancementLevel level) {
    final plan = state.analysis != null
        ? EnhancementPlan.fromAnalysis(state.analysis!, level)
        : state.plan;
    final newPlan = plan?.copyWith(level: level);

    state = state.copyWith(
      settings: EnhancementSettings.fromPlan(newPlan ?? state.plan!),
      plan: newPlan,
    );
  }

  void updateSettings(EnhancementSettings settings) {
    state = state.copyWith(settings: settings);
  }

  void toggleDenoise(bool enabled) {
    state = state.copyWith(
      settings: state.settings.copyWith(denoiseEnabled: enabled),
    );
  }

  void toggleSharpen(bool enabled) {
    state = state.copyWith(
      settings: state.settings.copyWith(sharpenEnabled: enabled),
    );
  }

  void toggleUpscale(bool enabled) {
    state = state.copyWith(
      settings: state.settings.copyWith(upscaleEnabled: enabled),
    );
  }

  void toggleColorGrade(bool enabled) {
    state = state.copyWith(
      settings: state.settings.copyWith(colorGradeEnabled: enabled),
    );
  }

  void toggleAudioEnhance(bool enabled) {
    state = state.copyWith(
      settings: state.settings.copyWith(audioEnhanceEnabled: enabled),
    );
  }

  Future<void> generatePreview() async {
    if (state.videoPath == null || state.analysis == null) return;

    state = state.copyWith(isProcessing: true, currentScreen: EnhancementScreen.preview);

    try {
      final frames = await _previewGenerator.generatePreviewFrames(
        videoPath: state.videoPath!,
        videoDuration: state.analysis!.metadata.duration,
        settings: state.settings,
      );

      state = state.copyWith(
        previewFrames: frames,
        isProcessing: false,
      );
    } catch (e) {
      state = state.copyWith(
        isProcessing: false,
        error: 'Preview generation failed: $e',
      );
    }
  }

  void selectPreviewFrame(int index) {
    state = state.copyWith(selectedPreviewIndex: index);
  }

  Future<void> startEnhancement() async {
    if (state.videoPath == null) return;

    final stopwatch = Stopwatch()..start();

    state = state.copyWith(
      isProcessing: true,
      currentScreen: EnhancementScreen.processing,
      progress: const EnhancementProgress(
        currentStage: 1,
        totalStages: 1,
        stageName: 'Enhancing...',
        progress: 0,
      ),
    );

    try {
      final outputPath = await _enhancer.enhanceVideoDirect(
        inputPath: state.videoPath!,
        settings: state.settings,
        totalDurationMs: state.analysis?.metadata.duration.inMilliseconds ?? 0,
        onProgress: (p) {
          state = state.copyWith(
            progress: EnhancementProgress(
              currentStage: 1,
              totalStages: 1,
              stageName: p >= 1.0 ? 'Finalizing...' : 'Enhancing...',
              progress: p,
            ),
          );
        },
      );
      stopwatch.stop();

      final result = EnhancementResult.success(
        outputPath: outputPath,
        originalMetadata: state.analysis!.metadata,
        processingTime: stopwatch.elapsed,
      );

      state = state.copyWith(
        result: result,
        isProcessing: false,
        currentScreen: EnhancementScreen.result,
      );
    } catch (e) {
      // Return to the plan screen so the user is not stranded on the
      // processing screen; the error surfaces there via AnalysisScreen/Plan.
      state = state.copyWith(
        isProcessing: false,
        currentScreen: EnhancementScreen.plan,
        error: 'Enhancement failed: $e',
      );
    }
  }

  /// Cancels the running FFmpeg encode and returns to the plan screen.
  void cancelEnhancement() {
    _enhancer.cancel();
    state = state.copyWith(
      isProcessing: false,
      currentScreen: EnhancementScreen.plan,
    );
  }

  void goToImport() {
    state = const EnhancementState();
  }

  void goToAnalysis() {
    state = state.copyWith(currentScreen: EnhancementScreen.analysis);
  }

  void goToPlan() {
    state = state.copyWith(currentScreen: EnhancementScreen.plan);
  }

  void goToPreview() {
    state = state.copyWith(currentScreen: EnhancementScreen.preview);
  }

  void goToProcessing() {
    state = state.copyWith(currentScreen: EnhancementScreen.processing);
  }

  void goToResult() {
    state = state.copyWith(currentScreen: EnhancementScreen.result);
  }

  void reset() {
    state = const EnhancementState();
  }
}

final enhancementProvider = NotifierProvider<EnhancementNotifier, EnhancementState>(
  () => EnhancementNotifier(),
);

extension EnhancementPlanCopyWith on EnhancementPlan {
  EnhancementPlan copyWith({
    EnhancementLevel? level,
  }) {
    return EnhancementPlan(
      level: level ?? this.level,
      actions: actions,
      willUpscale: willUpscale,
      willDenoise: willDenoise,
      willSharpen: willSharpen,
      willColorGrade: willColorGrade,
      willEnhanceAudio: willEnhanceAudio,
      estimatedDurationSeconds: estimatedDurationSeconds,
      estimatedOutputSizeMb: estimatedOutputSizeMb,
      analysis: analysis,
    );
  }
}