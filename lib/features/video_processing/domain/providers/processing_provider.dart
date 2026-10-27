import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/enums/export_quality.dart';
import '../../../../core/enums/processing_state.dart';
import '../../../../core/utils/result.dart';
import '../../../silence_detector/domain/entities/detection_params.dart';
import '../../../silence_detector/domain/entities/silence_removal_plan.dart';
import '../repositories/video_processor_repository.dart';
import '../../data/repositories/video_processor_repository_impl.dart';

final videoProcessorRepositoryProvider = Provider<VideoProcessorRepository>(
  (ref) => VideoProcessorRepositoryImpl(),
);

class ProcessingStateModel {
  final ProcessingState state;
  final double progress;
  final String statusMessage;
  final String? outputPath;
  final Failure? error;

  const ProcessingStateModel({
    this.state = ProcessingState.idle,
    this.progress = 0,
    this.statusMessage = '',
    this.outputPath,
    this.error,
  });

  ProcessingStateModel copyWith({
    ProcessingState? state,
    double? progress,
    String? statusMessage,
    String? outputPath,
    Failure? error,
  }) {
    return ProcessingStateModel(
      state: state ?? this.state,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      outputPath: outputPath ?? this.outputPath,
      error: error ?? this.error,
    );
  }
}

final processingStateProvider =
    NotifierProvider<ProcessingNotifier, ProcessingStateModel>(() {
      return ProcessingNotifier();
    });

class ProcessingNotifier extends Notifier<ProcessingStateModel> {
  @override
  ProcessingStateModel build() => const ProcessingStateModel();

  Future<void> startProcessing({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required ExportQuality quality,
    SmartZoomConfig? smartZoom,
  }) async {
    // Start from a fresh state: a stale outputPath from a previous run must
    // never be exported as if it were this run's result (copyWith cannot
    // null out fields).
    state = const ProcessingStateModel(
      state: ProcessingState.processing,
      progress: 0,
      statusMessage: 'Processing video...',
    );

    final repository = ref.read(videoProcessorRepositoryProvider);
    final result = await repository.processVideo(
      videoPath: videoPath,
      audioPath: audioPath,
      plan: plan,
      quality: quality,
      smartZoom: smartZoom,
      onProgress: (progress, status) {
        state = state.copyWith(progress: progress, statusMessage: status);
      },
    );

    if (result is AppError<String>) {
      state = state.copyWith(
        state: ProcessingState.failed,
        error: result.error,
      );
    } else if (result is Success<String>) {
      state = state.copyWith(
        state: ProcessingState.completed,
        progress: 1.0,
        statusMessage: 'Complete',
        outputPath: result.value,
      );
    }
  }

  void cancel() {
    state = state.copyWith(state: ProcessingState.cancelled);
  }

  void reset() {
    state = const ProcessingStateModel();
  }
}
